//  TelegramStore.swift
//  Aurora
//

import Foundation
import Combine
import AppKit
import OSLog
import GRDB

final class TelegramStore: ObservableObject {
    let log = Logger(subsystem: "com.aurora.app", category: "store")
    // TDLib
    let td = TDLibClient()
    private lazy var updateProcessor: TDLibUpdateProcessor = TDLibUpdateProcessor(store: self)
    private let receiver: TDLibReceiver
    // MARK: - Core published state

    @Published var authState: String = "unknown"

    @Published var selectedChatId: Int64?
    @Published var isLoadingHistory: Bool = false

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
    var didRequestInitialStorageStats = false
    let storageManager = StorageManager()

    // MARK: - Current user (Settings header)

    @Published var myUserId: Int64?
    @Published var myProfilePhotoPath: String?

    // MARK: - Chat avatars (paths)

    @Published var chatAvatarPathByChatId: [Int64: String] = [:]

    typealias ChatAvatarMeta = AvatarService.ChatAvatarMeta

    var chatAvatarMetaByChatId: [Int64: ChatAvatarMeta] = [:]
    var chatIdByAvatarFileId: [Int32: Int64] = [:]
    var requestedAvatarFileIds: Set<Int32> = []

    var myPhotoFileId: Int32?

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

    // MARK: - User cache (non-authoritative)
    // Нужно из extensions в других файлах
    var userCache: [Int64: TGUser] = [:]

    // MARK: - History jobs

    enum HistoryJobKind { case initialLocal, initialRemote, older }

    struct HistoryJob {
        let chatId: Int64
        let kind: HistoryJobKind
        let anchorMessageId: Int64
        let requestedLimit: Int
        let windowLimit: Int
        let onlyLocal: Bool
        let generation: Int
    }

    var historyJobs: [String: HistoryJob] = [:]
    var reachedHistoryStart: Set<Int64> = []
    var historyWindowLimitByChatId: [Int64: Int] = [:]
    var historyGenerationByChatId: [Int64: Int] = [:]

    // MARK: - Init

    init() {
        do {
            let db = try AppDatabase()
            database = db
        } catch {
            fatalError("Failed to initialize app database: \(error)")
        }
        dbPool = database.dbPool
        databaseRepository = AppDatabaseRepository(dbWriter: dbPool)
        databaseBatchWriter = DatabaseBatchWriter(repository: databaseRepository)

        
        guard let receiver = td.makeReceiver() else {
            fatalError("TDLib client not initialized")
        }
        self.receiver = receiver
        receiver.start()
        Task { [updateProcessor] in
            await updateProcessor.start(stream: receiver.stream)
        }

        td.send(#"{"@type":"getOption","name":"version"}"#)

        if let n = UserDefaults.standard.object(forKey: cacheLimitBytesKey) as? NSNumber {
            cacheLimitBytes = n.int64Value
        }

        restorePendingMessagesFromDatabase()
        startPendingCleanupTimer()
    }
    // MARK: - Computed

    var myDisplayName: String {
        guard let id = myUserId else { return "" }
        if let cached = userCache[id] {
            return cached.displayName
        }
        if let user = databaseRepository.fetchUser(userId: id) {
            userCache[id] = user
            return user.displayName
        }
        return ""
    }

    var isAuthorized: Bool {
        authState == "authorizationStateReady"
    }

    // MARK: - Public API (UI calls)

    func selectChat(_ chatId: Int64, forceReload: Bool = false) {
        let isSame = (selectedChatId == chatId)
        if !isSame { selectedChatId = chatId }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !forceReload, self.databaseRepository.hasMessages(chatId: chatId) {
                return
            }
            self.loadInitialHistory(chatId: chatId)
        }
    }

    func userDisplayName(_ userId: Int64?) -> String {
        guard let id = userId else { return "" }
        if let cached = userCache[id] {
            return cached.displayName
        }
        if let user = databaseRepository.fetchUser(userId: id) {
            userCache[id] = user
            return user.displayName
        }
        return "User \(id)"
    }

    // Read/viewed
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool = false) {
        let filteredIds = messageIds.filter { $0 > 0 }
#if DEBUG
        if filteredIds.count != messageIds.count {
            log.debug("viewMessages filtered invalid ids from \(messageIds, privacy: .public)")
        }
#endif
        guard !filteredIds.isEmpty else { return }
        let req: [String: Any] = [
            "@type": "viewMessages",
            "chat_id": chatId,
            "message_ids": filteredIds,
            "force_read": forceRead
        ]
        sendJSON(req)
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

    func persistChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        Task { await databaseBatchWriter.enqueue(.upsertChatLastMessage(chatId: chatId, messageId: messageId, preview: preview, date: date)) }
    }

    func persistUser(_ user: TGUser) {
        userCache[user.id] = user
        Task { await databaseBatchWriter.enqueue(.upsertUser(user)) }
    }

    func persistMessage(_ message: TGMessage) {
        Task { await databaseBatchWriter.enqueue(.upsertMessage(message)) }
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) {
        Task { await databaseBatchWriter.enqueue(.deleteMessages(chatId: chatId, messageIds: messageIds)) }
    }

    // Messages actions (implemented in +OptimisticSending)
    func sendText(chatId: Int64, text: String) { _sendText_impl(chatId: chatId, text: text) }
    func retrySend(message: TGMessage) { _retrySend_impl(message: message) }
    func cancelPending(message: TGMessage) { _cancelPending_impl(message: message) }
    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool = true) { _deleteMessages_impl(chatId: chatId, messageIds: messageIds, revoke: revoke) }
    func editMessageText(chatId: Int64, messageId: Int64, newText: String) { _editMessageText_impl(chatId: chatId, messageId: messageId, newText: newText) }

    // History paging (implemented in +History)
    func loadMoreHistory(chatId: Int64, anchorMessageId: Int64, pageSize: Int = 80) {
        _loadMoreHistory_impl(chatId: chatId, anchorMessageId: anchorMessageId, pageSize: pageSize)
    }

    // Storage (implemented in +Storage)
    func refreshStorageStatistics() { _refreshStorageStatistics_impl() }
    func applyCacheLimitBytes(_ bytes: Int64) { _applyCacheLimitBytes_impl(bytes) }
    func clearAllCache() { _clearAllCache_impl() }

    // Avatars/images (implemented in +Avatars)
    var myProfileNSImage: NSImage? { myProfileNSImage(pointSize: 36) }
    func myProfileNSImage(pointSize: CGFloat) -> NSImage? { _myProfileNSImage_impl(pointSize: pointSize) }

    func chatAvatarNSImage(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool = false,
        maxClamp: Int? = nil,
        kindOverride: String? = nil
    ) -> NSImage? {
        _chatAvatarNSImage_impl(chatId: chatId, pointSize: pointSize, preferHiRes: preferHiRes, maxClamp: maxClamp, kindOverride: kindOverride)
    }

    func chatAvatarNSImage(chatId: Int64) -> NSImage? {
        chatAvatarNSImage(chatId: chatId, pointSize: 40, preferHiRes: false)
    }

    func prefetchChatAvatarHiResIfNeeded(chatId: Int64) { _prefetchChatAvatarHiResIfNeeded_impl(chatId: chatId) }

    // MARK: - Authorization

    func submitPhoneNumber(_ phoneNumber: String) {
        let req: [String: Any] = [
            "@type": "setAuthenticationPhoneNumber",
            "phone_number": phoneNumber
        ]
        sendJSON(req)
    }

    func submitAuthCode(_ code: String) {
        let req: [String: Any] = [
            "@type": "checkAuthenticationCode",
            "code": code
        ]
        log.info("submit auth code")
        sendJSON(req)
    }

    func submitAuthPassword(_ password: String) {
        let req: [String: Any] = [
            "@type": "checkAuthenticationPassword",
            "password": password
        ]
        sendJSON(req)
    }

    func logOut() {
        authState = "authorizationStateLoggingOut"
        resetSessionState()
        sendJSON(["@type": "logOut"])
    }

    func resetSessionState() {
        userCache = [:]
        selectedChatId = nil
        isLoadingHistory = false

        storageByFileType = []
        storageTotalBytes = 0
        storageLastRefreshedAt = nil
        storageExtrasInFlight = []
        didRequestInitialStorageStats = false

        myUserId = nil
        myProfilePhotoPath = nil

        chatAvatarPathByChatId = [:]
        chatAvatarMetaByChatId = [:]
        chatIdByAvatarFileId = [:]
        requestedAvatarFileIds = []
        myPhotoFileId = nil

        lastParsedUpdate = nil
        lastParsedObject = nil

        pendingByLocalId = [:]
        localIdBySendingId = [:]
        localIdByTempMessageId = [:]
        serverMessageIdByLocalId = [:]
        nextLocalTempId = -1
        pendingMetrics = PendingMetrics()

        pendingCleanupTimer?.invalidate()
        pendingCleanupTimer = nil

        historyJobs = [:]
        reachedHistoryStart = []
        historyWindowLimitByChatId = [:]
        historyGenerationByChatId = [:]

        didLoadInitialData = false
        didSendTdlibParameters = false
        didRequestInitialStorageStats = false

        startPendingCleanupTimer()
    }
}
