//  TelegramStore.swift
//  Aurora
//

import Foundation
import Combine
import AppKit
import OSLog
import GRDB

final class TelegramStore: ObservableObject {
    enum Mode {
        case live
        case preview
    }

    static var preview: TelegramStore {
        TelegramStore(mode: .preview)
    }

    let log = Logger(subsystem: "com.aurora.app", category: "store")
    let mode: Mode
    // TDLib
    let td: TDLibClientType
    private lazy var updateProcessor: TDLibUpdateProcessor = TDLibUpdateProcessor(store: self)
    private let receiver: TDLibReceiver?
    private let tdlibHighPriorityRequestQueue = DispatchQueue(label: "com.aurora.app.tdlib.request.high.queue", qos: .userInitiated)
    private let tdlibLowPriorityRequestQueue = DispatchQueue(label: "com.aurora.app.tdlib.request.low.queue", qos: .utility)
    private let userPrefetchQueue = DispatchQueue(label: "com.aurora.app.user.prefetch.queue", qos: .utility)
    private let chatLastMessageWatermarkQueue = DispatchQueue(label: "com.aurora.app.chat.lastmessage.watermark.queue")
    private let authSnapshotQueue = DispatchQueue(label: "com.aurora.app.auth.snapshot.queue", attributes: .concurrent)
    private var authStateSnapshot: String = "unknown"
    private var isAuthorizedSnapshot: Bool = false
    private let viewMessagesCoordinator = ViewMessagesCoordinator()
    private let downloadLimiter = TDLibDownloadLimiter(maxConcurrent: 4)
    let messageStore = MessageStore()
    // MARK: - Core published state

    @Published var authState: String = "unknown"
    @Published private(set) var isAuthorized: Bool = false

    @Published var selectedChatId: Int64?
    @Published var isLoadingHistory: Bool = false
    @Published private(set) var pendingMessageJumpRequest: MessageJumpRequest?

    // MARK: - App DB

    let database: AppDatabase
    let databaseRepository: AppDatabaseRepository
    let databaseBatchWriter: DatabaseBatchWriter
    let dbPool: DatabasePool
    @Published var lastDatabaseStats: DatabaseStats?

    // MARK: - Storage / Cache (Settings)

    @Published var storageByFileType: [StorageFileTypeStat] = []
    @Published var storageTotalBytes: Int64 = 0
    @Published var storageLastRefreshedAt: Date? = nil
    @Published var cacheLimitBytes: Int64 = 2_147_483_648 // 2 GB default

    let cacheLimitBytesKey = "aurora.cache_limit_bytes"
    var storageExtrasInFlight: Set<String> = []
    var storageRefreshTasks: [Task<Void, Never>] = []
    var didRequestInitialStorageStats = false
    let storageManager = StorageManager()

    // MARK: - Current user (Settings header)

    @Published var myUserId: Int64?
    @Published var myProfilePhotoPath: String?

    // MARK: - Chat avatars (paths)

    @Published var chatAvatarPathByChatId: [Int64: String] = [:]
    @Published var chatAvatarVersionByChatId: [Int64: Int] = [:]
    private var pendingAvatarPathUpdates: [Int64: String?] = [:]
    private var avatarPathPublishTask: Task<Void, Never>?
    private let avatarPathPublishDelayNs: UInt64 = 40_000_000

    typealias ChatAvatarMeta = AvatarService.ChatAvatarMeta

    var chatAvatarMetaByChatId: [Int64: ChatAvatarMeta] = [:]
    var chatIdByAvatarFileId: [Int32: Int64] = [:]
    var requestedAvatarFileIds: Set<Int32> = []

    var myPhotoFileId: Int32?

    // MARK: - Message media thumbs (photo/video)

    var mediaStateByMessageKey: [TGMessageMediaKey: TGMediaState] = [:]
    let mediaProgressProvider = MediaProgressProvider()
    private var pendingMediaStateUpdates: [TGMessageMediaKey: TGMediaState?] = [:]
    private var mediaStatePublishTask: Task<Void, Never>?
    private let mediaStatePublishDelayNs: UInt64 = 40_000_000

    lazy var mediaService: MediaService = MediaService(
        scheduleDownload: { [weak self] fileId, priority, reason in
            self?.scheduleDownloadFile(fileId: fileId, priority: priority, reason: reason)
        },
        publishState: { [weak self] key, state in
            guard let self else { return }
            self.queueMediaStateUpdate(key: key, state: state)
        }
    )

    // MARK: - JSON parsing cache

    var lastParsedUpdate: String?
    var lastParsedObject: [String: Any]?
#if DEBUG
    private var debugCachedParseCount = 0
    private let debugCachedParseLogInterval = 200
#endif

    // MARK: - Avatar service

    let avatarService = AvatarService()

    // MARK: - Boot flags

    var didLoadInitialData = false
    var didSendTdlibParameters = false

    // MARK: - Optimistic sending infra

    struct PendingLink {
        let chatId: Int64
        var placeholderId: Int64
        let localId: UUID
        var sendingId: Int32
        let text: String
        let date: Int
        let isOutgoing: Bool
        let senderUserId: Int64?
        let replyToMessageId: Int64?
        let contentType: String
        let rawText: String?
        let entities: [TGTextEntity]
        let attachmentFingerprint: String?
        var retryCount: Int
        var nextRetryAt: Int?
    }

    var pendingByLocalId: [UUID: PendingLink] = [:]
    var localIdBySendingId: [Int32: UUID] = [:]
    var localIdByTempMessageId: [Int64: UUID] = [:]
    var serverMessageIdByLocalId: [UUID: Int64] = [:]
    var nextLocalTempId: Int64 = -1
    var pendingCleanupTimer: Timer? = nil

    let pendingTtlSeconds: Int = 10 * 60

    struct PendingMetrics {
        var reconcileBySendingId: Int = 0
        var reconcileByFunctionResponseExtra: Int = 0
        var reconcileByFallback: Int = 0
        var fallbackAmbiguous: Int = 0
        var coalesceRemovedCount: Int = 0
    }

    var pendingMetrics = PendingMetrics()
    var pendingChatInfoRequests: Set<Int64> = []
    var requestedUserIds: Set<Int64> = []

    struct ChatLastMessageWatermark: Equatable {
        let messageId: Int64
        let preview: String
        let date: Int
    }

    var chatLastMessageWatermarkByChatId: [Int64: ChatLastMessageWatermark] = [:]

    // MARK: - User cache (non-authoritative)
    // Нужно из extensions в других файлах
    var userCache: [Int64: TGUser] = [:]
    var userPrefetchInFlight: Set<Int64> = []

    // MARK: - TDLib pagination contexts (Settings)

    struct TDLibPaginationState<Item: Equatable>: Equatable {
        var items: [Item]
        var isLoadingMore: Bool
        var canLoadMore: Bool
        var offset: Int
        var error: String?
    }

    struct BlockedSenderItem: Identifiable, Hashable, Sendable {
        enum Kind: String, Hashable, Sendable {
            case user
            case chat
        }

        let kind: Kind
        let peerId: Int64
        var title: String

        var id: String {
            "\(kind.rawValue):\(peerId)"
        }
    }

    enum BlockedSenderRef: Hashable, Sendable {
        case user(Int64)
        case chat(Int64)
    }

    @Published private(set) var blockedSendersPagination = TDLibPaginationState<BlockedSenderItem>(
        items: [],
        isLoadingMore: false,
        canLoadMore: true,
        offset: 0,
        error: nil
    )
    private var blockedSendersInFlightExtras: Set<String> = []
    private var blockedSendersRequestedLimitByExtra: [String: Int] = [:]
    private var blockedSendersRequestedOffsetByExtra: [String: Int] = [:]

    // MARK: - History jobs

    enum HistoryJobKind { case initialLocal, initialRemote, older, around }
    enum PaginationAnchorSource: String { case storeMin, uiTop, other }

    enum MessageJumpSource: String, Sendable {
        case reply
        case jump
        case search
        case selection
        case restore
        case other
    }

    struct MessageJumpRequest: Identifiable, Equatable, Sendable {
        let id: UUID
        let chatId: Int64
        let messageId: Int64
        let source: MessageJumpSource
    }

    struct HistoryJob {
        let chatId: Int64
        let kind: HistoryJobKind
        let anchorMessageId: Int64
        let requestedLimit: Int
        let windowLimit: Int
        let onlyLocal: Bool
        let generation: Int
        let anchorSource: PaginationAnchorSource
        let uiTopMessageId: Int64?
        let uiTopKind: String?
        let storeMinIdVisible: Int64?
    }

    struct HistoryMetrics {
        var requestsLocal = 0
        var requestsRemote = 0
        var responses = 0
        var staleResponses = 0
        var emptyResponses = 0
        var olderResponsesWithoutOlder = 0
        var accumulatedLatencyMs: Double = 0
        var maxLatencyMs: Double = 0
        var maxInFlightJobs = 0
    }

    var historyJobs: [String: HistoryJob] = [:]
    var reachedHistoryStart: Set<Int64> = []
    var historyWindowLimitByChatId: [Int64: Int] = [:]
    var historyGenerationByChatId: [Int64: Int] = [:]
    var initialRemoteRequestedGenerationByChatId: [Int64: Int] = [:]
    var historyRequestStartedAtNs: [String: UInt64] = [:]
    var historyNoProgressByChatId: [Int64: (anchorMessageId: Int64, attempts: Int)] = [:]
    var historyMetrics = HistoryMetrics()
    var historyGlobalPausedUntilNs: UInt64 = 0
    var historyPausedUntilNsByChatId: [Int64: UInt64] = [:]
    var historyPaginationStateByChatId: [Int64: HistoryPaginationContextState] = [:]

    // MARK: - Init

    init(mode: Mode = .live, tdClient: TDLibClientType? = nil) {
        self.mode = mode
        self.td = tdClient ?? Self.makeTDClient(mode: mode)
        do {
            let dbMode: AppDatabase.StorageMode = (mode == .preview) ? .preview : .persistent
            let db = try AppDatabase(storageMode: dbMode)
            database = db
        } catch {
            fatalError("Failed to initialize app database: \(error)")
        }
        dbPool = database.dbPool
        databaseRepository = AppDatabaseRepository(dbWriter: dbPool)
        databaseBatchWriter = DatabaseBatchWriter(repository: databaseRepository)

        if let n = UserDefaults.standard.object(forKey: cacheLimitBytesKey) as? NSNumber {
            cacheLimitBytes = n.int64Value
        }

        switch mode {
        case .live:
            guard let receiver = td.makeReceiver() else {
                fatalError("TDLib client not initialized")
            }
            self.receiver = receiver
            receiver.start()
            Task { [updateProcessor] in
                await updateProcessor.start(stream: receiver.stream)
            }
            td.send(#"{"@type":"getOption","name":"version"}"#)
            updateAuthorizationSnapshot(state: authState, authorized: isAuthorized)
            restorePendingMessagesFromDatabase()
            startPendingCleanupTimer()
        case .preview:
            self.receiver = nil
            configurePreviewState()
        }
    }

    private static func makeTDClient(mode: Mode) -> TDLibClientType {
        switch mode {
        case .live:
            return TDLibClient()
        case .preview:
            return MockTDLibClient()
        }
    }

    private func configurePreviewState() {
        authState = "authorizationStateReady"
        isAuthorized = true
        didLoadInitialData = true
        didSendTdlibParameters = true
        didRequestInitialStorageStats = true
        updateAuthorizationSnapshot(state: authState, authorized: isAuthorized)

        let now = Int(Date().timeIntervalSince1970)
        let me = TGUser(id: 7_001, firstName: "Aurora", lastName: "Preview", username: "aurora_preview")
        let teammate = TGUser(id: 7_002, firstName: "Alex", lastName: "Taylor", username: "alex")

        let chatAId: Int64 = 101
        let chatBId: Int64 = 202
        let messages: [TGMessage] = [
            TGMessage(
                id: 3_001,
                chatId: chatAId,
                date: now - 480,
                isOutgoing: false,
                senderUserId: teammate.id,
                text: "Morning! The SwiftUI snapshot now renders instantly."
            ),
            TGMessage(
                id: 3_002,
                chatId: chatAId,
                date: now - 210,
                isOutgoing: true,
                senderUserId: me.id,
                text: "Nice. I also disabled network calls in preview mode."
            ),
            TGMessage(
                id: 3_003,
                chatId: chatAId,
                date: now - 75,
                isOutgoing: false,
                senderUserId: teammate.id,
                text: "Looks great. Let's ship this setup."
            ),
            TGMessage(
                id: 4_001,
                chatId: chatBId,
                date: now - 1_300,
                isOutgoing: false,
                senderUserId: teammate.id,
                text: "Draft for release notes is in the docs."
            )
        ]

        let chats: [TGChat] = [
            TGChat(
                id: chatAId,
                title: "Preview Playground",
                kind: .basicGroup,
                order: 9_999_999,
                lastMessagePreview: "Looks great. Let's ship this setup.",
                lastMessageDate: now - 75,
                unreadCount: 0,
                lastReadInboxMessageId: 3_003,
                lastMessageId: 3_003
            ),
            TGChat(
                id: chatBId,
                title: "Product Notes",
                kind: .privateChat,
                order: 9_999_000,
                lastMessagePreview: "Draft for release notes is in the docs.",
                lastMessageDate: now - 1_300,
                unreadCount: 1,
                lastReadInboxMessageId: 0,
                lastMessageId: 4_001
            )
        ]

        myUserId = me.id
        userCache[me.id] = me
        userCache[teammate.id] = teammate
        selectedChatId = chatAId
        historyWindowLimitByChatId[chatAId] = 160
        historyWindowLimitByChatId[chatBId] = 160

        databaseRepository.upsertUser(me)
        databaseRepository.upsertUser(teammate)
        databaseRepository.upsertChats(chats)
        databaseRepository.upsertMessages(messages)
        databaseRepository.upsertChatLastMessage(chatId: chatAId, messageId: 3_003, preview: "Looks great. Let's ship this setup.", date: now - 75)
        databaseRepository.upsertChatLastMessage(chatId: chatBId, messageId: 4_001, preview: "Draft for release notes is in the docs.", date: now - 1_300)
    }

    // MARK: - Computed

    @MainActor
    var myDisplayName: String {
        guard let id = myUserId else { return "" }
        if let cached = userCache[id] {
            return cached.displayName
        }
        prefetchUserIfNeeded(userId: id)
        return ""
    }

    // MARK: - Public API (UI calls)

    func selectChat(_ chatId: Int64, forceReload: Bool = false) {
        let isSame = (selectedChatId == chatId)
        if !isSame {
            selectedChatId = chatId
            AuroraRuntimeMetrics.shared.incrementPublish("storeSelectedChat")
        }
        syncHistoryLoadingFlagForSelectedChat()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let hasWindow = await MainActor.run { [weak self] in
                guard let self else { return false }
                return !forceReload && self.historyWindowLimitByChatId[chatId] != nil
            }
            if hasWindow {
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.selectedChatId == chatId else { return }
                self.loadInitialHistory(chatId: chatId)
            }
        }
    }

    @MainActor
    func requestMessageJump(
        chatId: Int64,
        messageId: Int64,
        source: MessageJumpSource = .jump
    ) {
        guard messageId > 0 else { return }
        pendingMessageJumpRequest = MessageJumpRequest(
            id: UUID(),
            chatId: chatId,
            messageId: messageId,
            source: source
        )
    }

    @MainActor
    func consumeMessageJumpRequest(requestId: UUID) {
        guard let request = pendingMessageJumpRequest else { return }
        guard request.id == requestId else { return }
        pendingMessageJumpRequest = nil
    }

    @MainActor
    func userDisplayName(_ userId: Int64?) -> String {
        guard let id = userId else { return "" }
        if let cached = userCache[id] {
            return cached.displayName
        }
        prefetchUserIfNeeded(userId: id)
        return "User \(id)"
    }

    @MainActor
    func ensureBlockedSendersPaginationStarted() {
        guard blockedSendersPagination.items.isEmpty else { return }
        _ = loadMoreBlockedSenders()
    }

    @MainActor
    func reloadBlockedSendersPagination() {
        blockedSendersInFlightExtras.removeAll(keepingCapacity: false)
        blockedSendersRequestedLimitByExtra.removeAll(keepingCapacity: false)
        blockedSendersRequestedOffsetByExtra.removeAll(keepingCapacity: false)
        blockedSendersPagination = TDLibPaginationState(
            items: [],
            isLoadingMore: false,
            canLoadMore: true,
            offset: 0,
            error: nil
        )
        _ = loadMoreBlockedSenders()
    }

    @MainActor
    @discardableResult
    func loadMoreBlockedSenders(limit: Int = 50) -> Bool {
        guard !blockedSendersPagination.isLoadingMore else { return false }
        guard blockedSendersPagination.canLoadMore else { return false }
        guard isRequestAuthorizedSnapshot() else {
            blockedSendersPagination.error = "Требуется авторизация в Telegram"
            return false
        }

        let normalizedLimit = max(1, min(limit, 200))
        let requestOffset = blockedSendersPagination.offset
        let extra = "blockedSenders:main:\(UUID().uuidString)"

        blockedSendersInFlightExtras.insert(extra)
        blockedSendersRequestedLimitByExtra[extra] = normalizedLimit
        blockedSendersRequestedOffsetByExtra[extra] = requestOffset
        blockedSendersPagination.isLoadingMore = true
        blockedSendersPagination.error = nil

        enqueueTDLibRequest(
            [
                "@type": "getBlockedMessageSenders",
                "@extra": extra,
                "block_list": [
                    "@type": "blockListMain"
                ],
                "offset": requestOffset,
                "limit": normalizedLimit
            ],
            typeOverride: "getBlockedMessageSenders",
            priority: .high
        )
        return true
    }

    @MainActor
    func handleBlockedSendersResponse(extra: String, totalCount: Int, senders: [BlockedSenderRef]) {
        guard blockedSendersInFlightExtras.remove(extra) != nil else { return }
        let _ = blockedSendersRequestedLimitByExtra.removeValue(forKey: extra)
        let requestOffset = blockedSendersRequestedOffsetByExtra.removeValue(forKey: extra) ?? blockedSendersPagination.offset

        let incomingItems = senders.map { blockedSenderItem(for: $0) }
        let mergedItems = mergeBlockedSenderItems(existing: blockedSendersPagination.items, incoming: incomingItems)

        let nextOffset = requestOffset + senders.count
        let canLoadMore = senders.isEmpty ? false : (nextOffset < totalCount)

        blockedSendersPagination = TDLibPaginationState(
            items: mergedItems,
            isLoadingMore: false,
            canLoadMore: canLoadMore,
            offset: nextOffset,
            error: nil
        )
    }

    @MainActor
    func handleBlockedSendersError(extra: String, message: String) {
        guard blockedSendersInFlightExtras.remove(extra) != nil else { return }
        blockedSendersRequestedLimitByExtra.removeValue(forKey: extra)
        blockedSendersRequestedOffsetByExtra.removeValue(forKey: extra)
        blockedSendersPagination.isLoadingMore = false
        blockedSendersPagination.error = message
    }

    @MainActor
    func refreshBlockedSenderTitle(userId: Int64) {
        var items = blockedSendersPagination.items
        var changed = false
        for index in items.indices {
            guard items[index].kind == .user, items[index].peerId == userId else { continue }
            let title = resolveBlockedSenderTitle(kind: .user, peerId: userId)
            if items[index].title != title {
                items[index].title = title
                changed = true
            }
        }
        guard changed else { return }
        blockedSendersPagination.items = items
    }

    @MainActor
    func refreshBlockedSenderTitle(chatId: Int64, preferredTitle: String? = nil) {
        var items = blockedSendersPagination.items
        var changed = false
        for index in items.indices {
            guard items[index].kind == .chat, items[index].peerId == chatId else { continue }
            let title = preferredTitle ?? resolveBlockedSenderTitle(kind: .chat, peerId: chatId)
            if items[index].title != title {
                items[index].title = title
                changed = true
            }
        }
        guard changed else { return }
        blockedSendersPagination.items = items
    }

    @MainActor
    private func blockedSenderItem(for sender: BlockedSenderRef) -> BlockedSenderItem {
        switch sender {
        case let .user(userId):
            return BlockedSenderItem(
                kind: .user,
                peerId: userId,
                title: resolveBlockedSenderTitle(kind: .user, peerId: userId)
            )
        case let .chat(chatId):
            return BlockedSenderItem(
                kind: .chat,
                peerId: chatId,
                title: resolveBlockedSenderTitle(kind: .chat, peerId: chatId)
            )
        }
    }

    @MainActor
    private func resolveBlockedSenderTitle(kind: BlockedSenderItem.Kind, peerId: Int64) -> String {
        switch kind {
        case .user:
            if let cached = userCache[peerId] {
                return cached.displayName
            }
            if let persisted = databaseRepository.fetchUser(userId: peerId) {
                if userCache[peerId] != persisted {
                    userCache[peerId] = persisted
                }
                return persisted.displayName
            }
            Task { [weak self] in
                await self?.requestUserIfNeeded(peerId)
            }
            return "User \(peerId)"
        case .chat:
            if let chat = databaseRepository.fetchChat(chatId: peerId), !chat.title.isEmpty {
                return chat.title
            }
            if !pendingChatInfoRequests.contains(peerId) {
                pendingChatInfoRequests.insert(peerId)
                enqueueTDLibRequest(
                    [
                        "@type": "getChat",
                        "chat_id": peerId
                    ],
                    typeOverride: "getChat"
                )
            }
            return "Chat \(peerId)"
        }
    }

    private func mergeBlockedSenderItems(
        existing: [BlockedSenderItem],
        incoming: [BlockedSenderItem]
    ) -> [BlockedSenderItem] {
        var merged = existing
        var existingIds = Set(existing.map(\.id))
        for item in incoming {
            if existingIds.contains(item.id) {
                if let index = merged.firstIndex(where: { $0.id == item.id }), merged[index] != item {
                    merged[index] = item
                }
                continue
            }
            merged.append(item)
            existingIds.insert(item.id)
        }
        return merged
    }

    @MainActor
    private func prefetchUserIfNeeded(userId: Int64) {
        guard userId > 0 else { return }
        guard userCache[userId] == nil else { return }
        guard !userPrefetchInFlight.contains(userId) else { return }
        userPrefetchInFlight.insert(userId)

        let repository = databaseRepository
        userPrefetchQueue.async { [weak self] in
            let persisted = repository.fetchUser(userId: userId)
            DispatchQueue.main.async {
                guard let self else { return }
                self.userPrefetchInFlight.remove(userId)

                if let persisted {
                    let changed = self.userCache[userId] != persisted
                    self.userCache[userId] = persisted
                    if changed {
                        self.objectWillChange.send()
                    }
                    return
                }

                Task { [weak self] in
                    await self?.requestUserIfNeeded(userId)
                }
            }
        }
    }

    // Read/viewed
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool = false) {
        let positiveIds = messageIds.filter { $0 > 0 }
        let filteredIds = Array(Set(positiveIds)).sorted()
#if DEBUG
        if positiveIds.count != messageIds.count {
            log.debug("viewMessages filtered invalid ids from \(messageIds, privacy: .public)")
        }
        if filteredIds.count != positiveIds.count {
            log.debug("viewMessages deduped \(positiveIds.count - filteredIds.count, privacy: .public) duplicate ids")
        }
#endif
        guard !filteredIds.isEmpty else { return }
        sendViewMessagesNow(
            chatId: chatId,
            messageIds: filteredIds,
            forceRead: forceRead,
            reason: "fromDirectViewMessages"
        )
    }

    func reportVisibleMessages(chatId: Int64, minMessageId: Int64?, maxMessageId: Int64?, messageIds: [Int64]) {
        let sortedIds = Array(Set(messageIds.filter { $0 > 0 })).sorted()
        let lo = minMessageId.map(String.init) ?? "n/a"
        let hi = maxMessageId.map(String.init) ?? "n/a"
        let firstId = sortedIds.first.map(String.init) ?? "n/a"
        let lastId = sortedIds.last.map(String.init) ?? "n/a"
        SwiftUIPublishTrace.storeEvent(
            name: "viewMessages_requested",
            chatId: chatId,
            details: "range=\(lo)..\(hi) count=\(sortedIds.count) first=\(firstId) last=\(lastId)",
            reason: "fromVisibleRange"
        )
        viewMessagesCoordinator.schedule(
            chatId: chatId,
            minMessageId: minMessageId,
            maxMessageId: maxMessageId,
            messageIds: sortedIds
        ) { [weak self] scheduledChatId, ids in
            self?.sendViewMessagesNow(
                chatId: scheduledChatId,
                messageIds: ids,
                forceRead: false,
                reason: "fromVisibleRange"
            )
        }
    }

    func resetVisibleMessageTracking(chatId: Int64) {
        viewMessagesCoordinator.reset(chatId: chatId)
    }

    func resetVisibleMessageTracking() {
        viewMessagesCoordinator.resetAll()
    }

    func sendViewMessagesNow(chatId: Int64, messageIds: [Int64], forceRead: Bool, reason: String) {
        let sortedIds = Array(Set(messageIds.filter { $0 > 0 })).sorted()
        guard !sortedIds.isEmpty else { return }
        let firstId = sortedIds.first.map(String.init) ?? "n/a"
        let lastId = sortedIds.last.map(String.init) ?? "n/a"
        SwiftUIPublishTrace.storeEvent(
            name: "viewMessages_sent",
            chatId: chatId,
            details: "count=\(sortedIds.count) first=\(firstId) last=\(lastId) forceRead=\(forceRead)",
            reason: reason
        )
        let req: [String: Any] = [
            "@type": "viewMessages",
            "chat_id": chatId,
            "message_ids": sortedIds,
            "force_read": forceRead
        ]
        enqueueTDLibRequest(req, typeOverride: "viewMessages", priority: .low)
    }

    func markChatAsReadToLatestIfNeeded(chatId: Int64) {
        guard let c = databaseRepository.fetchChat(chatId: chatId) else { return }
        if c.unreadCount <= 0 { return }
        if c.lastMessageId == 0 { return }
        viewMessages(chatId: chatId, messageIds: [c.lastMessageId], forceRead: true)
    }

    func printDatabaseStats() {
        let stats = databaseRepository.fetchStats()
        lastDatabaseStats = stats
        log.info("db stats chats=\(stats.chats) messages=\(stats.messages) users=\(stats.users)")
    }

    private func cacheParsedObject(json: String, obj: [String: Any]?) {
        guard let obj else { return }
        lastParsedUpdate = json
        lastParsedObject = obj
#if DEBUG
        debugCachedParseCount += 1
        if debugCachedParseCount % debugCachedParseLogInterval == 0 {
            log.debug("cached objects injected=\(self.debugCachedParseCount, privacy: .public)")
        }
#endif
    }

    // MARK: - App DB helpers

    func persistChat(_ chat: TGChat) {
        Task { await databaseBatchWriter.enqueue(.upsertChat(chat)) }
    }

    func flushDatabaseNow() {
        Task { await databaseBatchWriter.flushNow() }
    }

    func messageSnapshotStream(chatId: Int64, windowSize: Int) async -> AsyncStream<[TGMessage]> {
        await messageStore.subscribe(chatId: chatId, windowLimit: windowSize)
    }

    func setMessageWindow(chatId: Int64, windowSize: Int) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.messageStore.setWindowLimit(chatId: chatId, limit: windowSize)
        }
    }

    func updateMessageWindowFocus(chatId: Int64, isFollowingLatest: Bool, anchorMessageId: Int64?) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.messageStore.setWindowFocus(
                chatId: chatId,
                isFollowingLatest: isFollowingLatest,
                anchorMessageId: anchorMessageId
            )
        }
    }

    func updateMessageStoreLiveScrolling(chatId: Int64, isLiveScrolling: Bool, anchorMessageId: Int64?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.messageStore.setLiveScrolling(
                chatId: chatId,
                isLiveScrolling: isLiveScrolling,
                anchorMessageId: anchorMessageId
            )
        }
    }

    func primeMessageStore(chatId: Int64, limit: Int) async {
        let fetched = databaseRepository.fetchLatestMessages(chatId: chatId, limit: limit)
        guard !fetched.isEmpty else {
            await messageStore.setWindowLimit(chatId: chatId, limit: limit)
            return
        }
        _ = await messageStore.mergeMessages(chatId: chatId, messages: fetched, windowLimit: limit)
    }

    func ensureMediaThumbnail(
        chatId: Int64,
        messageId: Int64,
        descriptor: TGMessageMediaDescriptor,
        targetPointSize: CGSize,
        screenScale: CGFloat
    ) async -> TGMediaState {
        await mediaService.ensureThumbnail(
            chatId: chatId,
            messageId: messageId,
            descriptor: descriptor,
            targetPointSize: targetPointSize,
            screenScale: screenScale
        )
    }

    func ensureMediaImage(
        chatId: Int64,
        messageId: Int64,
        descriptor: TGMessageMediaDescriptor,
        targetPointSize: CGSize,
        screenScale: CGFloat
    ) async -> TGMediaState {
        await mediaService.ensureImage(
            chatId: chatId,
            messageId: messageId,
            descriptor: descriptor,
            targetPointSize: targetPointSize,
            screenScale: screenScale
        )
    }

    @MainActor
    func mediaState(chatId: Int64, messageId: Int64) -> TGMediaState? {
        mediaProgressProvider.state(chatId: chatId, messageId: messageId)
    }

    func handleMediaFileUpdate(_ update: TGFileUpdate) async {
        await mediaService.handleFileUpdate(update)
    }

    @MainActor
    func clearMediaState(chatId: Int64) {
        pendingMediaStateUpdates = pendingMediaStateUpdates.filter { $0.key.chatId != chatId }
        mediaStateByMessageKey = mediaStateByMessageKey.filter { $0.key.chatId != chatId }
        mediaProgressProvider.clear(chatId: chatId)
        Task {
            await mediaService.clear(chatId: chatId)
        }
    }

    func persistChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        recordChatLastMessageWatermark(chatId: chatId, messageId: messageId, preview: preview, date: date)
        Task { await databaseBatchWriter.enqueue(.upsertChatLastMessage(chatId: chatId, messageId: messageId, preview: preview, date: date)) }
    }

    func shouldEnqueueChatLastMessageUpdate(chatId: Int64, messageId: Int64, preview: String, date: Int) -> Bool {
        chatLastMessageWatermarkQueue.sync {
            let incoming = ChatLastMessageWatermark(messageId: messageId, preview: preview, date: date)
            if let current = chatLastMessageWatermarkByChatId[chatId] {
                if current.messageId > incoming.messageId {
                    return false
                }
                if current == incoming {
                    return false
                }
            }
            chatLastMessageWatermarkByChatId[chatId] = incoming
            return true
        }
    }

    func recordChatLastMessageWatermark(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        chatLastMessageWatermarkQueue.sync {
            chatLastMessageWatermarkByChatId[chatId] = ChatLastMessageWatermark(
                messageId: messageId,
                preview: preview,
                date: date
            )
        }
    }

    func persistUser(_ user: TGUser) {
        Task { @MainActor [weak self] in
            self?.userCache[user.id] = user
        }
        Task { await databaseBatchWriter.enqueue(.upsertUser(user)) }
    }

    func persistMessage(_ message: TGMessage) {
        Task {
            _ = await messageStore.mergeMessages(
                chatId: message.chatId,
                messages: [message],
                windowLimit: historyWindowLimitByChatId[message.chatId] ?? 160
            )
            await databaseBatchWriter.enqueue(.upsertMessage(message))
        }
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) {
        Task {
            _ = await messageStore.applyDelete(chatId: chatId, messageIds: messageIds)
            await databaseBatchWriter.enqueue(.deleteMessages(chatId: chatId, messageIds: messageIds))
        }
    }

    // Messages actions (implemented in +OptimisticSending)
    func sendText(chatId: Int64, text: String) { _sendText_impl(chatId: chatId, text: text) }
    func retrySend(message: TGMessage) { _retrySend_impl(message: message) }
    func cancelPending(message: TGMessage) { _cancelPending_impl(message: message) }
    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool = true) { _deleteMessages_impl(chatId: chatId, messageIds: messageIds, revoke: revoke) }
    func editMessageText(chatId: Int64, messageId: Int64, newText: String) { _editMessageText_impl(chatId: chatId, messageId: messageId, newText: newText) }

    // History paging (implemented in +History)
    @discardableResult
    func loadMoreHistory(
        chatId: Int64,
        anchorMessageId: Int64,
        pageSize: Int = 50,
        uiTopMessageId: Int64? = nil,
        uiTopKind: String? = nil,
        storeMinIdVisible: Int64? = nil,
        anchorSource: PaginationAnchorSource = .other
    ) -> Bool {
        _loadMoreHistory_impl(
            chatId: chatId,
            anchorMessageId: anchorMessageId,
            pageSize: pageSize,
            uiTopMessageId: uiTopMessageId,
            uiTopKind: uiTopKind,
            storeMinIdVisible: storeMinIdVisible,
            anchorSource: anchorSource
        )
    }

    @MainActor
    func ensureMessageAvailableForScroll(
        chatId: Int64,
        messageId: Int64,
        timeoutNs: UInt64 = 4_000_000_000
    ) async -> Bool {
        guard messageId > 0 else { return false }

        if await messageStore.containsOrderedMessageId(chatId: chatId, messageId: messageId) {
            return true
        }

#if DEBUG
        log.debug("ensure message for scroll started chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
#endif

        _ = await messageStore.setWindowFocus(
            chatId: chatId,
            isFollowingLatest: false,
            anchorMessageId: messageId
        )

        if let persisted = databaseRepository.fetchMessage(chatId: chatId, messageId: messageId) {
            _ = await messageStore.mergeMessages(
                chatId: chatId,
                messages: [persisted],
                windowLimit: historyWindowLimitByChatId[chatId] ?? 160
            )
            if await messageStore.containsOrderedMessageId(chatId: chatId, messageId: messageId) {
                return true
            }
        }

        let pageSize = max(50, min(100, (historyWindowLimitByChatId[chatId] ?? 160) / 2))
        var requestedAround = loadHistoryAroundMessage(
            chatId: chatId,
            messageId: messageId,
            pageSize: pageSize
        )
        let pollNs: UInt64 = 120_000_000
        let startedAtNs = DispatchTime.now().uptimeNanoseconds

        while DispatchTime.now().uptimeNanoseconds &- startedAtNs < timeoutNs {
            if await messageStore.containsOrderedMessageId(chatId: chatId, messageId: messageId) {
#if DEBUG
                log.debug("ensure message for scroll resolved chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
#endif
                return true
            }
            if !requestedAround,
               !historyJobs.values.contains(where: { $0.chatId == chatId && $0.kind == .around }) {
                requestedAround = loadHistoryAroundMessage(
                    chatId: chatId,
                    messageId: messageId,
                    pageSize: pageSize
                )
            }
            try? await Task.sleep(nanoseconds: pollNs)
            if Task.isCancelled {
                return false
            }
        }

        let available = await messageStore.containsOrderedMessageId(chatId: chatId, messageId: messageId)
#if DEBUG
        if !available {
            log.error("ensure message for scroll timeout chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
        }
#endif
        return available
    }

    // Storage (implemented in +Storage)
    @MainActor func refreshStorageStatistics() { _refreshStorageStatistics_impl() }
    @MainActor func applyCacheLimitBytes(_ bytes: Int64) { _applyCacheLimitBytes_impl(bytes) }
    @MainActor func clearAllCache() { _clearAllCache_impl() }

    // Avatars/images (implemented in +Avatars)
    @MainActor
    var myProfileNSImage: NSImage? { myProfileNSImage(pointSize: 36) }

    @MainActor
    func myProfileNSImage(pointSize: CGFloat) -> NSImage? { _myProfileNSImage_impl(pointSize: pointSize) }

    @MainActor
    func chatAvatarNSImage(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool = false,
        maxClamp: Int? = nil,
        kindOverride: String? = nil
    ) -> NSImage? {
        _chatAvatarNSImage_impl(chatId: chatId, pointSize: pointSize, preferHiRes: preferHiRes, maxClamp: maxClamp, kindOverride: kindOverride)
    }

    @MainActor
    func chatAvatarNSImage(chatId: Int64) -> NSImage? {
        chatAvatarNSImage(chatId: chatId, pointSize: 40, preferHiRes: false)
    }

    @MainActor
    func prefetchChatAvatarHiResIfNeeded(chatId: Int64) {
        _prefetchChatAvatarHiResIfNeeded_impl(chatId: chatId)
    }

    @MainActor
    func chatAvatarNSImageAsync(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool = false,
        maxClamp: Int? = nil,
        kindOverride: String? = nil
    ) async -> NSImage? {
        chatAvatarNSImage(
            chatId: chatId,
            pointSize: pointSize,
            preferHiRes: preferHiRes,
            maxClamp: maxClamp,
            kindOverride: kindOverride
        )
    }

    @MainActor
    func chatAvatarNSImageAsync(chatId: Int64) async -> NSImage? {
        chatAvatarNSImage(chatId: chatId)
    }

    // MARK: - Authorization

    @MainActor
    func applyAuthorizationState(_ newState: String) {
        let previous = authState
        authState = newState
        isAuthorized = (newState == "authorizationStateReady")
        AuroraRuntimeMetrics.shared.incrementPublish("storeAuth")
        updateAuthorizationSnapshot(state: authState, authorized: isAuthorized)
        if newState == "authorizationStateClosed" {
            resetSessionState()
        } else if previous == "authorizationStateReady", newState != "authorizationStateReady" {
            resetSessionState()
        }
        if !isAuthorized {
            cancelStorageRefreshTasks()
        }
    }

    func submitPhoneNumber(_ phoneNumber: String) {
        guard authState == "authorizationStateWaitPhoneNumber" else {
            log.info("Blocked TDLib request (unexpected auth state): setAuthenticationPhoneNumber")
            return
        }
        let req: [String: Any] = [
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": phoneNumber
        ]
        sendJSON(req)
    }

    func submitAuthCode(_ code: String) {
        guard authState == "authorizationStateWaitCode" else {
            log.info("Blocked TDLib request (unexpected auth state): checkAuthenticationCode")
            return
        }
        guard let cleanCode = sanitizeAuthCode(code) else {
            log.info("Blocked TDLib request (invalid auth code format): checkAuthenticationCode")
            return
        }
        let req: [String: Any] = [
            "@type": "checkAuthenticationCode",
            "code": cleanCode
        ]
        log.info("submit auth code")
        sendJSON(req)
    }

    func submitAuthPassword(_ password: String) {
        guard authState == "authorizationStateWaitPassword" else {
            log.info("Blocked TDLib request (unexpected auth state): checkAuthenticationPassword")
            return
        }
        let req: [String: Any] = [
            "@type": "checkAuthenticationPassword",
            "password": password
        ]
        sendJSON(req)
    }

    private func sanitizeAuthCode(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.allSatisfy({ $0.isNumber }) else { return nil }
        guard (3...8).contains(compact.count) else { return nil }
        return compact
    }

    @MainActor
    func logOut() {
        sendJSON(["@type": "logOut"])
    }

    @MainActor
    func resetSessionState() {
        isAuthorized = false
        updateAuthorizationSnapshot(state: authState, authorized: isAuthorized)
        userCache = [:]
        userPrefetchInFlight = []
        requestedUserIds = []
        chatLastMessageWatermarkQueue.sync {
            chatLastMessageWatermarkByChatId.removeAll(keepingCapacity: false)
        }
        selectedChatId = nil
        isLoadingHistory = false

        storageByFileType = []
        storageTotalBytes = 0
        storageLastRefreshedAt = nil
        storageExtrasInFlight = []
        didRequestInitialStorageStats = false

        myUserId = nil
        myProfilePhotoPath = nil

        avatarPathPublishTask?.cancel()
        avatarPathPublishTask = nil
        pendingAvatarPathUpdates = [:]
        chatAvatarPathByChatId = [:]
        chatAvatarVersionByChatId = [:]
        chatAvatarMetaByChatId = [:]
        chatIdByAvatarFileId = [:]
        requestedAvatarFileIds = []
        myPhotoFileId = nil

        mediaStatePublishTask?.cancel()
        mediaStatePublishTask = nil
        pendingMediaStateUpdates = [:]
        mediaStateByMessageKey = [:]
        mediaProgressProvider.reset()
        Task { await mediaService.reset() }

        lastParsedUpdate = nil
        lastParsedObject = nil

        pendingByLocalId = [:]
        localIdBySendingId = [:]
        localIdByTempMessageId = [:]
        serverMessageIdByLocalId = [:]
        nextLocalTempId = -1
        pendingMetrics = PendingMetrics()
        pendingChatInfoRequests = []

        pendingCleanupTimer?.invalidate()
        pendingCleanupTimer = nil

        historyJobs = [:]
        reachedHistoryStart = []
        historyWindowLimitByChatId = [:]
        historyGenerationByChatId = [:]
        initialRemoteRequestedGenerationByChatId = [:]
        historyRequestStartedAtNs = [:]
        historyNoProgressByChatId = [:]
        historyMetrics = HistoryMetrics()
        historyGlobalPausedUntilNs = 0
        historyPausedUntilNsByChatId = [:]
        historyPaginationStateByChatId = [:]

        blockedSendersPagination = TDLibPaginationState(
            items: [],
            isLoadingMore: false,
            canLoadMore: true,
            offset: 0,
            error: nil
        )
        blockedSendersInFlightExtras = []
        blockedSendersRequestedLimitByExtra = [:]
        blockedSendersRequestedOffsetByExtra = [:]

        didLoadInitialData = false
        didSendTdlibParameters = false
        didRequestInitialStorageStats = false

        viewMessagesCoordinator.resetAll()
        downloadLimiter.reset()
        Task { await messageStore.reset() }

        if mode == .live {
            startPendingCleanupTimer()
        }
    }

    private func authorizationSnapshot() -> (state: String, isAuthorized: Bool) {
        authSnapshotQueue.sync {
            (authStateSnapshot, isAuthorizedSnapshot)
        }
    }

    private func updateAuthorizationSnapshot(state: String, authorized: Bool) {
        authSnapshotQueue.sync(flags: .barrier) {
            authStateSnapshot = state
            isAuthorizedSnapshot = authorized
        }
    }

    func currentAuthorizationStateSnapshot() -> String {
        authorizationSnapshot().state
    }

    func isRequestAuthorizedSnapshot() -> Bool {
        authorizationSnapshot().isAuthorized
    }

    func enqueueTDLibRequest(
        _ req: [String: Any],
        typeOverride: String? = nil,
        priority: TDLibClient.SendPriority = .high
    ) {
        let queue: DispatchQueue = {
            switch priority {
            case .high: return tdlibHighPriorityRequestQueue
            case .low: return tdlibLowPriorityRequestQueue
            }
        }()
        queue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            let queueLabel = String(cString: __dispatch_queue_get_label(nil))
            let type = typeOverride
                ?? (req["@type"] as? String)
                ?? "unknown"
            self.log.debug("tdlib request type=\(type, privacy: .public) priority=\(priority.rawValue, privacy: .public) queue=\(queueLabel, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
#endif
            if self.sendIfAuthorized(req, typeOverride: typeOverride, priority: priority) {
                let type = typeOverride
                    ?? (req["@type"] as? String)
                    ?? "unknown"
                AuroraRuntimeMetrics.shared.incrementRequest(type)
            }
        }
    }

    func scheduleDownloadFile(fileId: Int32, priority: Int, reason: String) {
        downloadLimiter.enqueue(fileId: fileId, priority: priority, reason: reason) { [weak self] req in
            self?.enqueueTDLibRequest(req, typeOverride: "downloadFile")
        }
    }

    func markDownloadCompleted(fileId: Int32) {
        downloadLimiter.markCompleted(fileId: fileId)
    }

    @MainActor
    func debugAssertAvatarStateAccess(_ context: StaticString = #function) {
#if DEBUG
        let contextString = String(describing: context)
        if !Thread.isMainThread {
            log.fault("avatar storage access off-main context=\(contextString, privacy: .public)")
            assertionFailure("Avatar storage access off-main context=\(contextString)")
        }
        let metaStorage: Any = chatAvatarMetaByChatId
        guard metaStorage is [Int64: ChatAvatarMeta] else {
            log.fault("avatar meta storage unexpected type context=\(contextString, privacy: .public)")
            assertionFailure("Unexpected avatar meta storage type: \(type(of: metaStorage))")
            return
        }
        let pathStorage: Any = chatAvatarPathByChatId
        guard pathStorage is [Int64: String] else {
            log.fault("avatar path storage unexpected type context=\(contextString, privacy: .public)")
            assertionFailure("Unexpected avatar path storage type: \(type(of: pathStorage))")
            return
        }
#endif
    }

    @MainActor
    func queueChatAvatarPathUpdate(chatId: Int64, path: String?) {
        debugAssertAvatarStateAccess()
        let normalized: String? = {
            guard let path, !path.isEmpty else { return nil }
            return path
        }()
        if pendingAvatarPathUpdates[chatId] == normalized,
           chatAvatarPathByChatId[chatId] == normalized {
            return
        }
        pendingAvatarPathUpdates[chatId] = normalized
        scheduleAvatarPathPublishIfNeeded()
    }

    @MainActor
    func bumpChatAvatarVersion(chatId: Int64) {
        let current = chatAvatarVersionByChatId[chatId] ?? 0
        chatAvatarVersionByChatId[chatId] = current &+ 1
    }

    @MainActor
    private func scheduleAvatarPathPublishIfNeeded() {
        debugAssertAvatarStateAccess()
        guard avatarPathPublishTask == nil else { return }
        avatarPathPublishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.avatarPathPublishDelayNs)
            await self.flushQueuedAvatarPathUpdates(attempt: 0)
        }
    }

    @MainActor
    private func flushQueuedAvatarPathUpdates(attempt: Int) async {
        debugAssertAvatarStateAccess()
        guard !pendingAvatarPathUpdates.isEmpty else {
            avatarPathPublishTask = nil
            return
        }

        if ViewUpdatePhaseTracker.shared.isViewUpdating, attempt < 8 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            await flushQueuedAvatarPathUpdates(attempt: attempt + 1)
            return
        }

        var nextPaths = chatAvatarPathByChatId
        for (chatId, path) in pendingAvatarPathUpdates {
            if let path {
                nextPaths[chatId] = path
            } else {
                nextPaths.removeValue(forKey: chatId)
            }
        }
        pendingAvatarPathUpdates.removeAll(keepingCapacity: true)
        avatarPathPublishTask = nil

        if nextPaths != chatAvatarPathByChatId {
            chatAvatarPathByChatId = nextPaths
        }
    }

    @MainActor
    private func queueMediaStateUpdate(key: TGMessageMediaKey, state: TGMediaState?) {
        if pendingMediaStateUpdates[key] == state,
           mediaStateByMessageKey[key] == state {
            return
        }
        pendingMediaStateUpdates[key] = state
        scheduleMediaStatePublishIfNeeded()
    }

    @MainActor
    private func scheduleMediaStatePublishIfNeeded() {
        guard mediaStatePublishTask == nil else { return }
        mediaStatePublishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.mediaStatePublishDelayNs)
            await self.flushQueuedMediaStateUpdates(attempt: 0)
        }
    }

    @MainActor
    private func flushQueuedMediaStateUpdates(attempt: Int) async {
        guard !pendingMediaStateUpdates.isEmpty else {
            mediaStatePublishTask = nil
            return
        }

        if ViewUpdatePhaseTracker.shared.isViewUpdating, attempt < 8 {
            try? await Task.sleep(nanoseconds: 16_000_000)
            await flushQueuedMediaStateUpdates(attempt: attempt + 1)
            return
        }

        var nextStateByKey = mediaStateByMessageKey
        var changedStates: [(key: TGMessageMediaKey, state: TGMediaState?)] = []
        for (key, state) in pendingMediaStateUpdates {
            if nextStateByKey[key] == state { continue }
            if let state {
                nextStateByKey[key] = state
            } else {
                nextStateByKey.removeValue(forKey: key)
            }
            changedStates.append((key: key, state: state))
        }
        pendingMediaStateUpdates.removeAll(keepingCapacity: true)
        mediaStatePublishTask = nil

        guard !changedStates.isEmpty else { return }
        mediaStateByMessageKey = nextStateByKey
        for changed in changedStates {
            mediaProgressProvider.setState(changed.state, for: changed.key)
        }
    }
}

final class AuroraRuntimeMetrics {
    static let shared = AuroraRuntimeMetrics()

    private let log = Logger(subsystem: "com.aurora.app", category: "runtime.metrics")
    private let queue = DispatchQueue(label: "com.aurora.app.runtime.metrics.queue")
    private var requestCounters: [String: Int] = [:]
    private var publishCounters: [String: Int] = [:]
    private var timer: DispatchSourceTimer?

    private init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        self.timer = timer
        timer.resume()
    }

    func incrementRequest(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestCounters[name, default: 0] += 1
        }
    }

    func incrementPublish(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.publishCounters[name, default: 0] += 1
        }
    }

    private func flush() {
        let requestSnapshot = requestCounters
        let publishSnapshot = publishCounters
        requestCounters.removeAll(keepingCapacity: true)
        publishCounters.removeAll(keepingCapacity: true)

        if !requestSnapshot.isEmpty {
            let line = requestSnapshot
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            log.debug("tdlib rps \(line, privacy: .public)")
        }

        if !publishSnapshot.isEmpty {
            let line = publishSnapshot
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            log.debug("published/s \(line, privacy: .public)")
        }
    }
}

final class MainThreadPublishDebouncer<Value: Equatable> {
    private let queue = DispatchQueue(label: "com.aurora.app.main.publish.debouncer")
    private let delay: TimeInterval
    private let maxViewUpdateDeferrals = 12
    private let viewUpdateRetryDelay: TimeInterval = 0.010
    private let postPublishDelayNs: UInt64 = 6_000_000
    private var pendingValue: Value?
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func schedule(
        value: Value,
        chatId: Int64? = nil,
        source: String,
        publish: @escaping @MainActor (Value) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pendingValue == value {
                return
            }
            self.pendingValue = value
            let details = self.traceDetails(for: value)
            SwiftUIPublishTrace.storeEvent(
                name: "publish_scheduled",
                chatId: chatId,
                details: "source=\(source) delayMs=\(Int((self.delay * 1_000).rounded())) \(details)",
                reason: "debouncer"
            )
            self.workItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let snapshot = self.pendingValue else { return }
                self.pendingValue = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await Task.yield()
                        self.publishWhenSafe(
                            value: snapshot,
                            chatId: chatId,
                            source: source,
                            attempt: 0,
                            publish: publish
                        )
                    }
                }
            }
            self.workItem = item
            self.queue.asyncAfter(deadline: .now() + self.delay, execute: item)
        }
    }

    @MainActor
    private func publishWhenSafe(
        value: Value,
        chatId: Int64?,
        source: String,
        attempt: Int,
        publish: @escaping @MainActor (Value) -> Void
    ) {
        if ViewUpdatePhaseTracker.shared.isViewUpdating, attempt < maxViewUpdateDeferrals {
            let delay = viewUpdateRetryDelay * Double(attempt + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.publishWhenSafe(
                        value: value,
                        chatId: chatId,
                        source: source,
                        attempt: attempt + 1,
                        publish: publish
                    )
                }
            }
            return
        }

        SwiftUIPublishTrace.storeEvent(
            name: "publish_fire",
            chatId: chatId,
            details: "source=\(source) deferred=\(attempt) \(traceDetails(for: value))",
            reason: "debouncer"
        )
        DispatchQueue.main.async {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: self.postPublishDelayNs)
                await Task.yield()
                publish(value)
            }
        }
    }

    private func traceDetails(for value: Value) -> String {
        if let chats = value as? [TGChat] {
            let firstId = chats.first.map(\.id).map(String.init) ?? "n/a"
            let lastId = chats.last.map(\.id).map(String.init) ?? "n/a"
            return "count=\(chats.count) first=\(firstId) last=\(lastId)"
        }
        if let messages = value as? [TGMessage] {
            let firstId = messages.first.map(\.id).map(String.init) ?? "n/a"
            let lastId = messages.last.map(\.id).map(String.init) ?? "n/a"
            return "count=\(messages.count) first=\(firstId) last=\(lastId)"
        }
        return "valueType=\(String(describing: Value.self))"
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.workItem?.cancel()
            self.workItem = nil
            self.pendingValue = nil
        }
    }
}

final class ViewMessagesCoordinator {
    private struct RangeSignature: Equatable {
        let minId: Int64
        let maxId: Int64
    }

    private struct PendingState {
        var range: RangeSignature?
        var messageIds: Set<Int64>
        var workItem: DispatchWorkItem?
    }

    private let queue = DispatchQueue(label: "com.aurora.app.viewmessages.coordinator")
    private let debounceDelay: TimeInterval
    private let resendSuppressionWindowNs: UInt64
    private var pendingByChat: [Int64: PendingState] = [:]
    private var seenByChat: [Int64: Set<Int64>] = [:]
    private var lastSentRangeByChat: [Int64: RangeSignature] = [:]
    private var lastSentAtNsByChat: [Int64: UInt64] = [:]
    private var lastSentIdsByChat: [Int64: Set<Int64>] = [:]

    init(
        debounceDelay: TimeInterval = 0.25,
        resendSuppressionWindowNs: UInt64 = 300_000_000
    ) {
        self.debounceDelay = debounceDelay
        self.resendSuppressionWindowNs = resendSuppressionWindowNs
    }

    func schedule(
        chatId: Int64,
        minMessageId: Int64?,
        maxMessageId: Int64?,
        messageIds: [Int64],
        send: @escaping (Int64, [Int64]) -> Void
    ) {
        let filteredIds = messageIds.filter { $0 > 0 }
        guard !filteredIds.isEmpty else { return }
        let sortedInputIds = filteredIds.sorted()
        let range: RangeSignature? = {
            guard let min = minMessageId, let max = maxMessageId, min > 0, max > 0 else { return nil }
            return RangeSignature(minId: min, maxId: max)
        }()
        let inputRangeText: String = {
            guard let range else { return "n/a..n/a" }
            return "\(range.minId)..\(range.maxId)"
        }()

        queue.async { [weak self] in
            guard let self else { return }
            let inputFirst = sortedInputIds.first.map(String.init) ?? "n/a"
            let inputLast = sortedInputIds.last.map(String.init) ?? "n/a"
            SwiftUIPublishTrace.storeEvent(
                name: "viewMessages_requested",
                chatId: chatId,
                details: "source=ViewMessagesCoordinator_enqueue range=\(inputRangeText) count=\(sortedInputIds.count) first=\(inputFirst) last=\(inputLast)",
                reason: "fromVisibleRange"
            )
            var state = self.pendingByChat[chatId] ?? PendingState(range: nil, messageIds: [], workItem: nil)
            state.range = range
            state.messageIds.formUnion(filteredIds)
            state.workItem?.cancel()

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard let queued = self.pendingByChat[chatId] else { return }

                let alreadySeen = self.seenByChat[chatId] ?? []
                let unseen = queued.messageIds.subtracting(alreadySeen)
                let rangeChanged = queued.range != self.lastSentRangeByChat[chatId]
                guard rangeChanged || !unseen.isEmpty else {
                    self.pendingByChat.removeValue(forKey: chatId)
                    return
                }

                self.pendingByChat.removeValue(forKey: chatId)
                if let range = queued.range {
                    self.lastSentRangeByChat[chatId] = range
                }
                var seen = alreadySeen
                seen.formUnion(unseen)
                self.seenByChat[chatId] = seen

                let ids = unseen.sorted()
                guard !ids.isEmpty else { return }
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if let lastSentAt = self.lastSentAtNsByChat[chatId],
                   nowNs >= lastSentAt,
                   (nowNs - lastSentAt) <= self.resendSuppressionWindowNs,
                   let lastSentIds = self.lastSentIdsByChat[chatId],
                   unseen.isSubset(of: lastSentIds) {
                    let firstId = ids.first.map(String.init) ?? "n/a"
                    let lastId = ids.last.map(String.init) ?? "n/a"
                    SwiftUIPublishTrace.storeEvent(
                        name: "viewMessages_skipped",
                        chatId: chatId,
                        details: "source=ViewMessagesCoordinator_fire reason=duplicate_window count=\(ids.count) first=\(firstId) last=\(lastId)",
                        reason: "fromVisibleRange"
                    )
                    return
                }
                let firstId = ids.first.map(String.init) ?? "n/a"
                let lastId = ids.last.map(String.init) ?? "n/a"
                SwiftUIPublishTrace.storeEvent(
                    name: "viewMessages_sent",
                    chatId: chatId,
                    details: "source=ViewMessagesCoordinator_fire rangeChanged=\(rangeChanged) count=\(ids.count) first=\(firstId) last=\(lastId)",
                    reason: "fromVisibleRange"
                )
                send(chatId, ids)
                self.lastSentAtNsByChat[chatId] = nowNs
                self.lastSentIdsByChat[chatId] = Set(ids)
            }

            state.workItem = item
            self.pendingByChat[chatId] = state
            self.queue.asyncAfter(deadline: .now() + self.debounceDelay, execute: item)
        }
    }

    func reset(chatId: Int64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingByChat[chatId]?.workItem?.cancel()
            self.pendingByChat.removeValue(forKey: chatId)
            self.seenByChat.removeValue(forKey: chatId)
            self.lastSentRangeByChat.removeValue(forKey: chatId)
            self.lastSentAtNsByChat.removeValue(forKey: chatId)
            self.lastSentIdsByChat.removeValue(forKey: chatId)
        }
    }

    func resetAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, state) in self.pendingByChat {
                state.workItem?.cancel()
            }
            self.pendingByChat.removeAll(keepingCapacity: false)
            self.seenByChat.removeAll(keepingCapacity: false)
            self.lastSentRangeByChat.removeAll(keepingCapacity: false)
            self.lastSentAtNsByChat.removeAll(keepingCapacity: false)
            self.lastSentIdsByChat.removeAll(keepingCapacity: false)
        }
    }
}

final class TDLibDownloadLimiter {
    private struct Request {
        let fileId: Int32
        let priority: Int
        let reason: String
        let send: ([String: Any]) -> Void
    }

    private let queue = DispatchQueue(label: "com.aurora.app.download.limiter")
    private let maxConcurrent: Int
    private var pending: [Request] = []
    private var pendingIds: Set<Int32> = []
    private var inFlight: Set<Int32> = []
    private var inFlightStartedAt: [Int32: DispatchTime] = [:]
    private var completed: Set<Int32> = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func enqueue(
        fileId: Int32,
        priority: Int,
        reason: String,
        send: @escaping ([String: Any]) -> Void
    ) {
        guard fileId > 0 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if self.completed.contains(fileId) || self.inFlight.contains(fileId) || self.pendingIds.contains(fileId) {
                return
            }

            self.pending.append(Request(fileId: fileId, priority: priority, reason: reason, send: send))
            self.pendingIds.insert(fileId)
            self.drain()
        }
    }

    func markCompleted(fileId: Int32) {
        queue.async { [weak self] in
            guard let self else { return }
            self.inFlight.remove(fileId)
            self.inFlightStartedAt.removeValue(forKey: fileId)
            self.completed.insert(fileId)
            self.drain()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll(keepingCapacity: false)
            self.pendingIds.removeAll(keepingCapacity: false)
            self.inFlight.removeAll(keepingCapacity: false)
            self.inFlightStartedAt.removeAll(keepingCapacity: false)
            self.completed.removeAll(keepingCapacity: false)
        }
    }

    private func drain() {
        expireStalledRequests()
        while inFlight.count < maxConcurrent, !pending.isEmpty {
            let req = pending.removeFirst()
            pendingIds.remove(req.fileId)
            inFlight.insert(req.fileId)
            inFlightStartedAt[req.fileId] = .now()

            let payload: [String: Any] = [
                "@type": "downloadFile",
                "@extra": "download:\(req.reason):\(req.fileId)",
                "file_id": req.fileId,
                "priority": req.priority,
                "offset": 0,
                "limit": 0,
                "synchronous": false
            ]
            req.send(payload)
        }
    }

    private func expireStalledRequests(maxAgeSeconds: Double = 30.0) {
        guard !inFlightStartedAt.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let maxAgeNs = UInt64(maxAgeSeconds * 1_000_000_000)
        let stalled = inFlightStartedAt.compactMap { fileId, startedAt -> Int32? in
            let age = now - startedAt.uptimeNanoseconds
            return age > maxAgeNs ? fileId : nil
        }
        guard !stalled.isEmpty else { return }
        for fileId in stalled {
            inFlight.remove(fileId)
            inFlightStartedAt.removeValue(forKey: fileId)
        }
    }
}

actor MessageStore {
    struct HistoryTraceSnapshot: Sendable {
        let rawMinId: Int64
        let rawMaxId: Int64
        let rawCount: Int
        let visibleMinId: Int64
        let visibleMaxId: Int64
        let visibleCount: Int
    }

    struct DebugWindowSnapshot: Sendable {
        let windowLimit: Int
        let orderedCount: Int
        let modelsCount: Int
        let visibleCount: Int
        let trimsDeferredCount: Int
        let trimsAppliedAfterScrollCount: Int
        let trimsDuringLiveScrollCount: Int
    }

    struct WindowFocusState: Sendable, Equatable {
        let isFollowingLatest: Bool
        let anchorMessageId: Int64?
    }

    private struct MergeInsertionDelta {
        var prepended: Int = 0
        var appended: Int = 0
        var interior: Int = 0
    }

    private struct LiveScrollTrimMetrics: Sendable {
        var trimsDeferredCount: Int = 0
        var trimsAppliedAfterScrollCount: Int = 0
        var trimsDuringLiveScrollCount: Int = 0
    }

    private struct ChatState {
        var messagesById: [Int64: TGMessage] = [:]
        var orderedMessageIds: [Int64] = []
        var windowLimit: Int = 160
        var continuations: [UUID: AsyncStream<[TGMessage]>.Continuation] = [:]
        var lastPublishedSnapshot: [TGMessage] = []
        var publishTask: Task<Void, Never>?
    }

    private let log = Logger(subsystem: "com.aurora.app", category: "message.store")
    private let publishDebounceNs: UInt64
    private let maxMessagesPerChat: Int
    private let slidingWindowHardCap: Int
    private let followingLatestLowWatermarkGap: Int
    private let liveScrollOverflowCap: Int
    private let liveScrollSoftTrimTarget: Int
    private let sortBias: Int64 = 9_000_000_000_000_000_000
    private var chatStateById: [Int64: ChatState] = [:]
    private var windowFocusByChatId: [Int64: WindowFocusState] = [:]
    private var liveScrollingChatIds: Set<Int64> = []
    private var deferredTrimChatIds: Set<Int64> = []
    private var liveScrollTrimMetricsByChatId: [Int64: LiveScrollTrimMetrics] = [:]
    private var mutationCount = 0
#if DEBUG
    private let debugStoreWindowInvariantCap = 600
#endif

    init(
        publishDebounceMs: UInt64 = 33,
        maxMessagesPerChat: Int = 6_000,
        slidingWindowHardCap: Int = 600,
        followingLatestLowWatermarkGap: Int = 40,
        liveScrollOverflowCap: Int = 680,
        liveScrollSoftTrimTarget: Int = 650
    ) {
        self.publishDebounceNs = publishDebounceMs * 1_000_000
        self.maxMessagesPerChat = maxMessagesPerChat
        self.slidingWindowHardCap = max(40, slidingWindowHardCap)
        self.followingLatestLowWatermarkGap = max(0, followingLatestLowWatermarkGap)
        let overflowCap = max(self.slidingWindowHardCap, liveScrollOverflowCap)
        self.liveScrollOverflowCap = min(700, overflowCap)
        self.liveScrollSoftTrimTarget = min(
            self.liveScrollOverflowCap,
            max(self.slidingWindowHardCap, liveScrollSoftTrimTarget)
        )
    }

    func historyTraceSnapshot(chatId: Int64) -> HistoryTraceSnapshot {
        guard var chat = chatStateById[chatId] else {
            return HistoryTraceSnapshot(
                rawMinId: 0,
                rawMaxId: 0,
                rawCount: 0,
                visibleMinId: 0,
                visibleMaxId: 0,
                visibleCount: 0
            )
        }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        chatStateById[chatId] = chat

        let rawMinId = chat.orderedMessageIds.first ?? 0
        let rawMaxId = chat.orderedMessageIds.last ?? 0
        let rawCount = chat.messagesById.count

        let visible = snapshot(for: chat)
        let visibleMinId = visible.first?.id ?? 0
        let visibleMaxId = visible.last?.id ?? 0
        let visibleCount = visible.count

        return HistoryTraceSnapshot(
            rawMinId: rawMinId,
            rawMaxId: rawMaxId,
            rawCount: rawCount,
            visibleMinId: visibleMinId,
            visibleMaxId: visibleMaxId,
            visibleCount: visibleCount
        )
    }

    func debugWindowSnapshot(chatId: Int64) -> DebugWindowSnapshot {
        let metrics = liveScrollTrimMetricsByChatId[chatId] ?? LiveScrollTrimMetrics()
        guard var chat = chatStateById[chatId] else {
            return DebugWindowSnapshot(
                windowLimit: 160,
                orderedCount: 0,
                modelsCount: 0,
                visibleCount: 0,
                trimsDeferredCount: metrics.trimsDeferredCount,
                trimsAppliedAfterScrollCount: metrics.trimsAppliedAfterScrollCount,
                trimsDuringLiveScrollCount: metrics.trimsDuringLiveScrollCount
            )
        }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        chatStateById[chatId] = chat
        let visibleCount = snapshot(for: chat).count
        return DebugWindowSnapshot(
            windowLimit: chat.windowLimit,
            orderedCount: chat.orderedMessageIds.count,
            modelsCount: chat.messagesById.count,
            visibleCount: visibleCount,
            trimsDeferredCount: metrics.trimsDeferredCount,
            trimsAppliedAfterScrollCount: metrics.trimsAppliedAfterScrollCount,
            trimsDuringLiveScrollCount: metrics.trimsDuringLiveScrollCount
        )
    }

    func setLiveScrolling(chatId: Int64, isLiveScrolling: Bool, anchorMessageId: Int64?) {
        var chat = chatStateById[chatId] ?? ChatState()
        normalizeOrderedIdsIfNeeded(chat: &chat)

        if isLiveScrolling {
            liveScrollingChatIds.insert(chatId)
            chatStateById[chatId] = chat
            debugAssertStoreWindowCountInvariant(chatId: chatId, chat: chat, stage: "scrollStart")
            return
        }

        liveScrollingChatIds.remove(chatId)
        let hadDeferredTrim = deferredTrimChatIds.remove(chatId) != nil
        guard hadDeferredTrim else {
            chatStateById[chatId] = chat
            debugAssertStoreWindowCountInvariant(chatId: chatId, chat: chat, stage: "scrollEndIdle")
            return
        }

        let normalizedAnchor = anchorMessageId.flatMap { $0 > 0 ? $0 : nil }
        let focusOverride = normalizedAnchor.map {
            WindowFocusState(isFollowingLatest: false, anchorMessageId: $0)
        }

        let trimmed = trimToSlidingWindowIfNeeded(
            chatId: chatId,
            chat: &chat,
            delta: nil,
            focusOverride: focusOverride,
            forceApply: true
        )
        chatStateById[chatId] = chat
        debugAssertStoreWindowCountInvariant(chatId: chatId, chat: chat, stage: "scrollEndFlush")
        if trimmed {
            incrementTrimsAppliedAfterScroll(chatId: chatId)
            schedulePublish(chatId: chatId)
        }
    }

    func containsOrderedMessageId(chatId: Int64, messageId: Int64) -> Bool {
        guard messageId > 0 else { return false }
        guard var chat = chatStateById[chatId] else { return false }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        chatStateById[chatId] = chat
        return indexOfMessageId(messageId, in: chat.orderedMessageIds) != nil
    }

    func setWindowFocus(chatId: Int64, isFollowingLatest: Bool, anchorMessageId: Int64?) -> Bool {
        let normalizedAnchor = anchorMessageId.flatMap { $0 > 0 ? $0 : nil }
        let focus = WindowFocusState(
            isFollowingLatest: isFollowingLatest,
            anchorMessageId: normalizedAnchor
        )
        if windowFocusByChatId[chatId] == focus {
            return false
        }
        windowFocusByChatId[chatId] = focus
        guard var chat = chatStateById[chatId] else { return true }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        let trimmed = trimToSlidingWindowIfNeeded(chatId: chatId, chat: &chat, delta: nil)
        chatStateById[chatId] = chat
        if trimmed {
            schedulePublish(chatId: chatId)
        }
        return true
    }

    func subscribe(chatId: Int64, windowLimit: Int) -> AsyncStream<[TGMessage]> {
        let id = UUID()
        return AsyncStream<[TGMessage]>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task {
                self.attach(continuation: continuation, chatId: chatId, subscriberId: id, windowLimit: windowLimit)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.detach(chatId: chatId, subscriberId: id)
                }
            }
        }
    }

    func setWindowLimit(chatId: Int64, limit: Int) {
        var chat = chatStateById[chatId] ?? ChatState()
        normalizeOrderedIdsIfNeeded(chat: &chat)
        let bounded = max(40, min(limit, 5_000))
        guard chat.windowLimit != bounded else { return }
        chat.windowLimit = bounded
        _ = trimToSlidingWindowIfNeeded(chatId: chatId, chat: &chat, delta: nil)
        chatStateById[chatId] = chat
        schedulePublish(chatId: chatId)
    }

    @discardableResult
    func mergeMessages(chatId: Int64, messages: [TGMessage], windowLimit: Int? = nil) -> Int {
        guard !messages.isEmpty else {
            if let windowLimit {
                setWindowLimit(chatId: chatId, limit: windowLimit)
            }
            return 0
        }

        var chat = chatStateById[chatId] ?? ChatState()
        normalizeOrderedIdsIfNeeded(chat: &chat)
        if let windowLimit {
            chat.windowLimit = max(chat.windowLimit, min(windowLimit, 5_000))
        }

        let previousMinId = chat.orderedMessageIds.first
        let previousMaxId = chat.orderedMessageIds.last
        let previousMinKey = previousMinId.map(orderingKey(for:))
        let previousMaxKey = previousMaxId.map(orderingKey(for:))
        var insertionDelta = MergeInsertionDelta()

        var changed = 0
        for message in messages where message.chatId == chatId {
            let existing = chat.messagesById[message.id]
            if upsertMessage(&chat, message: message) {
                changed += 1
                guard existing == nil else { continue }
                let key = orderingKey(for: message.id)
                if let previousMinKey, key < previousMinKey {
                    insertionDelta.prepended += 1
                } else if let previousMaxKey, key > previousMaxKey {
                    insertionDelta.appended += 1
                } else if previousMinKey == nil || previousMaxKey == nil {
                    insertionDelta.appended += 1
                } else {
                    insertionDelta.interior += 1
                }
            }
        }

        if changed > 0 {
            pruneIfNeeded(chat: &chat)
            _ = trimToSlidingWindowIfNeeded(chatId: chatId, chat: &chat, delta: insertionDelta)
        }
        chatStateById[chatId] = chat
        debugAssertStoreWindowCountInvariant(chatId: chatId, chat: chat, stage: "merge")
        if changed > 0 {
            debugLogMutation(label: "merge", chatId: chatId, changed: changed)
            schedulePublish(chatId: chatId)
        } else if windowLimit != nil {
            schedulePublish(chatId: chatId)
        }
        return changed
    }

    @discardableResult
    func applyEdit(chatId: Int64, messageId: Int64, editDate: Int) -> Bool {
        guard var chat = chatStateById[chatId],
              var message = chat.messagesById[messageId]
        else { return false }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        let editedValue = editDate > 0 ? editDate : nil
        guard message.editedAt != editedValue else { return false }
        message.editedAt = editedValue
        chat.messagesById[messageId] = message
        chatStateById[chatId] = chat
        debugLogMutation(label: "edit", chatId: chatId, changed: 1)
        schedulePublish(chatId: chatId)
        return true
    }

    @discardableResult
    func applyContent(chatId: Int64, messageId: Int64, text: String) -> Bool {
        guard var chat = chatStateById[chatId],
              var message = chat.messagesById[messageId]
        else { return false }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        guard message.text != text else { return false }
        message.text = text
        chat.messagesById[messageId] = message
        chatStateById[chatId] = chat
        debugLogMutation(label: "content", chatId: chatId, changed: 1)
        schedulePublish(chatId: chatId)
        return true
    }

    @discardableResult
    func applyContentPayload(
        chatId: Int64,
        messageId: Int64,
        text: String,
        contentType: String,
        rawText: String?,
        entities: [TGTextEntity],
        media: TGMessageMediaDescriptor?
    ) -> Bool {
        guard var chat = chatStateById[chatId],
              var message = chat.messagesById[messageId]
        else { return false }
        normalizeOrderedIdsIfNeeded(chat: &chat)

        var hasChanges = false
        if message.text != text {
            message.text = text
            hasChanges = true
        }
        if message.rawText != rawText {
            message.rawText = rawText
            hasChanges = true
        }
        if message.entities != entities {
            message.entities = entities
            hasChanges = true
        }
        if message.contentType != contentType {
            message = TGMessage(
                id: message.id,
                chatId: message.chatId,
                date: message.date,
                isOutgoing: message.isOutgoing,
                senderUserId: message.senderUserId,
                text: message.text,
                contentType: contentType,
                rawText: message.rawText,
                entities: message.entities,
                media: message.media,
                sendState: message.sendState,
                replyToMessageId: message.replyToMessageId,
                localId: message.localId,
                sendingId: message.sendingId,
                editedAt: message.editedAt,
                canRetry: message.canRetry,
                retryCount: message.retryCount,
                nextRetryAt: message.nextRetryAt
            )
            hasChanges = true
        }
        if message.media != media {
            message.media = media
            hasChanges = true
        }

        guard hasChanges else { return false }
        chat.messagesById[messageId] = message
        chatStateById[chatId] = chat
        debugLogMutation(label: "contentPayload", chatId: chatId, changed: 1)
        schedulePublish(chatId: chatId)
        return true
    }

    @discardableResult
    func applyDelete(chatId: Int64, messageIds: [Int64]) -> Int {
        guard var chat = chatStateById[chatId], !messageIds.isEmpty else { return 0 }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        var removed = 0
        for id in messageIds {
            if chat.messagesById.removeValue(forKey: id) != nil {
                removeOrderedMessageId(&chat.orderedMessageIds, messageId: id)
                removed += 1
            }
        }
        guard removed > 0 else { return 0 }
        chatStateById[chatId] = chat
        debugLogMutation(label: "delete", chatId: chatId, changed: removed)
        schedulePublish(chatId: chatId)
        return removed
    }

    func reset() {
        for (_, chat) in chatStateById {
            chat.publishTask?.cancel()
        }
        chatStateById.removeAll(keepingCapacity: false)
        windowFocusByChatId.removeAll(keepingCapacity: false)
        liveScrollingChatIds.removeAll(keepingCapacity: false)
        deferredTrimChatIds.removeAll(keepingCapacity: false)
        liveScrollTrimMetricsByChatId.removeAll(keepingCapacity: false)
    }

    private func attach(
        continuation: AsyncStream<[TGMessage]>.Continuation,
        chatId: Int64,
        subscriberId: UUID,
        windowLimit: Int
    ) {
        var chat = chatStateById[chatId] ?? ChatState()
        normalizeOrderedIdsIfNeeded(chat: &chat)
        chat.windowLimit = max(chat.windowLimit, min(windowLimit, 5_000))
        _ = trimToSlidingWindowIfNeeded(chatId: chatId, chat: &chat, delta: nil)
        chat.continuations[subscriberId] = continuation
        chatStateById[chatId] = chat
        debugAssertStoreWindowCountInvariant(chatId: chatId, chat: chat, stage: "attach")
        continuation.yield(snapshot(for: chat))
    }

    private func detach(chatId: Int64, subscriberId: UUID) {
        guard var chat = chatStateById[chatId] else { return }
        chat.continuations.removeValue(forKey: subscriberId)
        chatStateById[chatId] = chat
    }

    private func schedulePublish(chatId: Int64) {
        guard var chat = chatStateById[chatId] else { return }
        guard !chat.continuations.isEmpty else {
            chat.publishTask?.cancel()
            chat.publishTask = nil
            chatStateById[chatId] = chat
            return
        }
        chat.publishTask?.cancel()
        let subscribersCount = chat.continuations.count
        Task { @MainActor in
            SwiftUIPublishTrace.storeEvent(
                name: "publish_scheduled",
                chatId: chatId,
                details: "source=MessageStore delayMs=\(publishDebounceNs / 1_000_000) subscribers=\(subscribersCount)",
                reason: "messageStore"
            )
        }
        chat.publishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.publishDebounceNs)
            await self.publish(chatId: chatId)
        }
        chatStateById[chatId] = chat
    }

    private func publish(chatId: Int64) {
        guard var chat = chatStateById[chatId] else { return }
        normalizeOrderedIdsIfNeeded(chat: &chat)
        debugAssertStoreWindowCountInvariant(chatId: chatId, chat: chat, stage: "publish")
        chat.publishTask = nil
        let newSnapshot = snapshot(for: chat)
        let subscribersCount = chat.continuations.count
        let firstId = newSnapshot.first.map(\.id).map(String.init) ?? "n/a"
        let lastId = newSnapshot.last.map(\.id).map(String.init) ?? "n/a"
        Task { @MainActor in
            SwiftUIPublishTrace.storeEvent(
                name: "snapshot_ready",
                chatId: chatId,
                details: "source=MessageStore count=\(newSnapshot.count) first=\(firstId) last=\(lastId) subscribers=\(subscribersCount)",
                reason: "messageSnapshotStream"
            )
        }
        guard newSnapshot != chat.lastPublishedSnapshot else {
            chatStateById[chatId] = chat
            return
        }
        Task { @MainActor in
            SwiftUIPublishTrace.storeEvent(
                name: "publish_fire",
                chatId: chatId,
                details: "source=MessageStore count=\(newSnapshot.count) subscribers=\(subscribersCount)",
                reason: "messageSnapshotStream"
            )
        }
        chat.lastPublishedSnapshot = newSnapshot
        let continuations = chat.continuations.values
        chatStateById[chatId] = chat
        for continuation in continuations {
            continuation.yield(newSnapshot)
        }
        Task { @MainActor in
            AuroraRuntimeMetrics.shared.incrementPublish("messageSnapshots")
        }
    }

    private func snapshot(for chat: ChatState) -> [TGMessage] {
        guard !chat.orderedMessageIds.isEmpty else { return [] }
        let boundedCount = min(chat.windowLimit, chat.orderedMessageIds.count)
        let start = chat.orderedMessageIds.count - boundedCount
        let ids = chat.orderedMessageIds[start...]
        var window: [TGMessage] = []
        window.reserveCapacity(boundedCount)
        for id in ids {
            if let message = chat.messagesById[id] {
                window.append(message)
            }
        }
        return window
    }

    private func orderingKey(for messageId: Int64) -> Int64 {
        if messageId > 0 {
            return messageId
        }
        return sortBias + messageId
    }

    private func pruneIfNeeded(chat: inout ChatState) {
        let overflow = chat.messagesById.count - maxMessagesPerChat
        guard overflow > 0 else { return }
        let overflowIds = chat.orderedMessageIds.prefix(overflow)
        for id in overflowIds {
            chat.messagesById.removeValue(forKey: id)
        }
        chat.orderedMessageIds.removeFirst(min(overflow, chat.orderedMessageIds.count))
    }

    private func trimToSlidingWindowIfNeeded(
        chatId: Int64,
        chat: inout ChatState,
        delta: MergeInsertionDelta?,
        focusOverride: WindowFocusState? = nil,
        forceApply: Bool = false
    ) -> Bool {
        let target = max(40, min(chat.windowLimit, slidingWindowHardCap))
        let count = chat.orderedMessageIds.count
        guard count > target else { return false }
        let isLiveScrolling = liveScrollingChatIds.contains(chatId)
        if isLiveScrolling && !forceApply {
            deferredTrimChatIds.insert(chatId)
            incrementTrimsDeferred(chatId: chatId)
            if count <= liveScrollOverflowCap {
                return false
            }
            let liveSoftTarget = max(target, liveScrollSoftTrimTarget)
            let didTrim = applyTrim(
                chatId: chatId,
                chat: &chat,
                delta: delta,
                target: liveSoftTarget,
                focusOverride: focusOverride,
                applyFollowingLowWatermark: false
            )
            if didTrim {
                incrementTrimsDuringLiveScroll(chatId: chatId)
            }
            return didTrim
        }

        return applyTrim(
            chatId: chatId,
            chat: &chat,
            delta: delta,
            target: target,
            focusOverride: focusOverride
        )
    }

    @discardableResult
    private func applyTrim(
        chatId: Int64,
        chat: inout ChatState,
        delta: MergeInsertionDelta?,
        target: Int,
        focusOverride: WindowFocusState?,
        applyFollowingLowWatermark: Bool = true
    ) -> Bool {
        let count = chat.orderedMessageIds.count
        guard count > target else { return false }
        let overflow = count - target
        let direction = insertionDirection(delta: delta)
        let focus = focusOverride
            ?? windowFocusByChatId[chatId]
            ?? WindowFocusState(isFollowingLatest: true, anchorMessageId: nil)

        if focus.isFollowingLatest {
            let preferred =
                applyFollowingLowWatermark
                ? max(40, target - followingLatestLowWatermarkGap)
                : target
            let removal = max(overflow, count - preferred)
            let evictedTop = min(removal, count)
            removePrefix(chat: &chat, count: removal)
            debugLogSlidingWindowEviction(
                chatId: chatId,
                mode: "following",
                direction: direction,
                beforeCount: count,
                target: target,
                evictedTop: evictedTop,
                evictedBottom: 0
            )
            return true
        }

        let anchorIndex: Int? = {
            guard let anchorId = focus.anchorMessageId else { return nil }
            if let exact = indexOfMessageId(anchorId, in: chat.orderedMessageIds) {
                return exact
            }
            let insertion = insertionIndex(for: anchorId, in: chat.orderedMessageIds)
            guard insertion < chat.orderedMessageIds.count else {
                return chat.orderedMessageIds.indices.last
            }
            return insertion
        }()

        guard let anchorIndex else {
            if let delta, delta.prepended > delta.appended {
                let evictedBottom = min(overflow, count)
                removeSuffix(chat: &chat, count: overflow)
                debugLogSlidingWindowEviction(
                    chatId: chatId,
                    mode: "anchored",
                    direction: "prepend",
                    beforeCount: count,
                    target: target,
                    evictedTop: 0,
                    evictedBottom: evictedBottom
                )
            } else {
                let evictedTop = min(overflow, count)
                removePrefix(chat: &chat, count: overflow)
                debugLogSlidingWindowEviction(
                    chatId: chatId,
                    mode: "anchored",
                    direction: "append",
                    beforeCount: count,
                    target: target,
                    evictedTop: evictedTop,
                    evictedBottom: 0
                )
            }
            return true
        }

        let anchorOffset: Int = {
            guard let delta else { return target / 2 }
            if delta.prepended > delta.appended {
                return target / 4
            }
            if delta.appended > delta.prepended {
                return (target * 3) / 4
            }
            return target / 2
        }()

        let maxStart = max(0, count - target)
        let unclampedStart = anchorIndex - anchorOffset
        let keepStart = min(max(0, unclampedStart), maxStart)
        let keepEnd = keepStart + target
        let removeHeadCount = keepStart
        let removeTailCount = max(0, count - keepEnd)
        if removeHeadCount > 0 {
            removePrefix(chat: &chat, count: removeHeadCount)
        }
        if removeTailCount > 0 {
            removeSuffix(chat: &chat, count: removeTailCount)
        }
        debugLogSlidingWindowEviction(
            chatId: chatId,
            mode: "anchored",
            direction: direction,
            beforeCount: count,
            target: target,
            evictedTop: removeHeadCount,
            evictedBottom: removeTailCount
        )
        return true
    }

    private func removePrefix(chat: inout ChatState, count: Int) {
        guard count > 0 else { return }
        let bounded = min(count, chat.orderedMessageIds.count)
        guard bounded > 0 else { return }
        let ids = chat.orderedMessageIds.prefix(bounded)
        for id in ids {
            chat.messagesById.removeValue(forKey: id)
        }
        chat.orderedMessageIds.removeFirst(bounded)
    }

    private func removeSuffix(chat: inout ChatState, count: Int) {
        guard count > 0 else { return }
        let bounded = min(count, chat.orderedMessageIds.count)
        guard bounded > 0 else { return }
        let ids = chat.orderedMessageIds.suffix(bounded)
        for id in ids {
            chat.messagesById.removeValue(forKey: id)
        }
        chat.orderedMessageIds.removeLast(bounded)
    }

    private func upsertMessage(_ chat: inout ChatState, message: TGMessage) -> Bool {
        let existing = chat.messagesById[message.id]
        guard existing != message else { return false }
        if existing == nil {
            let insertion = insertionIndex(for: message.id, in: chat.orderedMessageIds)
            chat.orderedMessageIds.insert(message.id, at: insertion)
        }
        chat.messagesById[message.id] = message
        return true
    }

    private func removeOrderedMessageId(_ orderedIds: inout [Int64], messageId: Int64) {
        guard let index = indexOfMessageId(messageId, in: orderedIds) else { return }
        orderedIds.remove(at: index)
    }

    private func normalizeOrderedIdsIfNeeded(chat: inout ChatState) {
        guard chat.orderedMessageIds.count != chat.messagesById.count else { return }
        chat.orderedMessageIds = chat.messagesById.keys.sorted { orderingKey(for: $0) < orderingKey(for: $1) }
    }

    private func insertionIndex(for messageId: Int64, in orderedIds: [Int64]) -> Int {
        let key = orderingKey(for: messageId)
        var low = 0
        var high = orderedIds.count
        while low < high {
            let mid = (low + high) / 2
            if orderingKey(for: orderedIds[mid]) < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func indexOfMessageId(_ messageId: Int64, in orderedIds: [Int64]) -> Int? {
        let key = orderingKey(for: messageId)
        var low = 0
        var high = orderedIds.count
        while low < high {
            let mid = (low + high) / 2
            let midKey = orderingKey(for: orderedIds[mid])
            if midKey < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < orderedIds.count, orderedIds[low] == messageId else { return nil }
        return low
    }

    private func insertionDirection(delta: MergeInsertionDelta?) -> String {
        guard let delta else { return "append" }
        return delta.prepended > delta.appended ? "prepend" : "append"
    }

    private func debugAssertStoreWindowCountInvariant(chatId: Int64, chat: ChatState, stage: String) {
#if DEBUG
        let cap =
            liveScrollingChatIds.contains(chatId)
            ? max(self.debugStoreWindowInvariantCap, self.liveScrollOverflowCap)
            : self.debugStoreWindowInvariantCap
        let storeWindowCount = chat.orderedMessageIds.count
        if storeWindowCount > cap {
            log.fault(
                "store window invariant violated chatId=\(chatId, privacy: .public) stage=\(stage, privacy: .public) storeWindowCount=\(storeWindowCount, privacy: .public) cap=\(cap, privacy: .public)"
            )
        }
        assert(
            storeWindowCount <= cap,
            "MessageStore invariant failed stage=\(stage) chatId=\(chatId) storeWindowCount=\(storeWindowCount) cap=\(cap)"
        )
#else
        _ = chatId
        _ = chat
        _ = stage
#endif
    }

    private func incrementTrimsDeferred(chatId: Int64) {
        var metrics = liveScrollTrimMetricsByChatId[chatId] ?? LiveScrollTrimMetrics()
        metrics.trimsDeferredCount += 1
        liveScrollTrimMetricsByChatId[chatId] = metrics
    }

    private func incrementTrimsAppliedAfterScroll(chatId: Int64) {
        var metrics = liveScrollTrimMetricsByChatId[chatId] ?? LiveScrollTrimMetrics()
        metrics.trimsAppliedAfterScrollCount += 1
        liveScrollTrimMetricsByChatId[chatId] = metrics
    }

    private func incrementTrimsDuringLiveScroll(chatId: Int64) {
        var metrics = liveScrollTrimMetricsByChatId[chatId] ?? LiveScrollTrimMetrics()
        metrics.trimsDuringLiveScrollCount += 1
        liveScrollTrimMetricsByChatId[chatId] = metrics
    }

    private func debugLogSlidingWindowEviction(
        chatId: Int64,
        mode: String,
        direction: String,
        beforeCount: Int,
        target: Int,
        evictedTop: Int,
        evictedBottom: Int
    ) {
#if DEBUG
        guard evictedTop > 0 || evictedBottom > 0 else { return }
        let afterCount = max(0, beforeCount - evictedTop - evictedBottom)
        log.debug(
            "sliding-window eviction chatId=\(chatId, privacy: .public) mode=\(mode, privacy: .public) direction=\(direction, privacy: .public) evictedTop=\(evictedTop, privacy: .public) evictedBottom=\(evictedBottom, privacy: .public) before=\(beforeCount, privacy: .public) after=\(afterCount, privacy: .public) target=\(target, privacy: .public)"
        )
#else
        _ = chatId
        _ = mode
        _ = direction
        _ = beforeCount
        _ = target
        _ = evictedTop
        _ = evictedBottom
#endif
    }

    private func debugLogMutation(label: String, chatId: Int64, changed: Int) {
#if DEBUG
        mutationCount += 1
        guard mutationCount == 1 || mutationCount % 50 == 0 else { return }
        let queueLabel = String(cString: __dispatch_queue_get_label(nil))
        log.debug(
            "message store \(label, privacy: .public) chatId=\(chatId, privacy: .public) changed=\(changed, privacy: .public) queue=\(queueLabel, privacy: .public) main=\(Thread.isMainThread, privacy: .public)"
        )
#endif
    }
}
