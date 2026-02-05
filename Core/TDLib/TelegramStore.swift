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
    private let tdlibRequestQueue = DispatchQueue(label: "com.aurora.app.tdlib.request.queue", qos: .userInitiated)
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
    var pendingChatInfoRequests: Set<Int64> = []
    var requestedUserIds: Set<Int64> = []

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
    var historyRequestStartedAtNs: [String: UInt64] = [:]
    var historyMetrics = HistoryMetrics()

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

        updateAuthorizationSnapshot(state: authState, authorized: isAuthorized)
        restorePendingMessagesFromDatabase()
        startPendingCleanupTimer()
    }
    // MARK: - Computed

    @MainActor
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

    // MARK: - Public API (UI calls)

    func selectChat(_ chatId: Int64, forceReload: Bool = false) {
        let isSame = (selectedChatId == chatId)
        if !isSame {
            selectedChatId = chatId
            AuroraRuntimeMetrics.shared.incrementPublish("storeSelectedChat")
        }
        syncHistoryLoadingFlagForSelectedChat()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.primeMessageStore(chatId: chatId, limit: 160)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !forceReload, self.historyWindowLimitByChatId[chatId] != nil {
                return
            }
            if !forceReload, self.databaseRepository.messageCount(chatId: chatId) > 0 {
                return
            }
            self.loadInitialHistory(chatId: chatId)
        }
    }

    @MainActor
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
        sendViewMessagesNow(chatId: chatId, messageIds: filteredIds, forceRead: forceRead)
    }

    func reportVisibleMessages(chatId: Int64, minMessageId: Int64?, maxMessageId: Int64?, messageIds: [Int64]) {
        viewMessagesCoordinator.schedule(
            chatId: chatId,
            minMessageId: minMessageId,
            maxMessageId: maxMessageId,
            messageIds: messageIds
        ) { [weak self] scheduledChatId, ids in
            self?.sendViewMessagesNow(chatId: scheduledChatId, messageIds: ids, forceRead: false)
        }
    }

    func resetVisibleMessageTracking(chatId: Int64) {
        viewMessagesCoordinator.reset(chatId: chatId)
    }

    func resetVisibleMessageTracking() {
        viewMessagesCoordinator.resetAll()
    }

    func sendViewMessagesNow(chatId: Int64, messageIds: [Int64], forceRead: Bool) {
        let req: [String: Any] = [
            "@type": "viewMessages",
            "chat_id": chatId,
            "message_ids": messageIds,
            "force_read": forceRead
        ]
        enqueueTDLibRequest(req, typeOverride: "viewMessages")
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
            await self.primeMessageStore(chatId: chatId, limit: windowSize)
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

    func persistChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        Task { await databaseBatchWriter.enqueue(.upsertChatLastMessage(chatId: chatId, messageId: messageId, preview: preview, date: date)) }
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
    func loadMoreHistory(chatId: Int64, anchorMessageId: Int64, pageSize: Int = 80) {
        _loadMoreHistory_impl(chatId: chatId, anchorMessageId: anchorMessageId, pageSize: pageSize)
    }

    // Storage (implemented in +Storage)
    @MainActor func refreshStorageStatistics() { _refreshStorageStatistics_impl() }
    @MainActor func applyCacheLimitBytes(_ bytes: Int64) { _applyCacheLimitBytes_impl(bytes) }
    @MainActor func clearAllCache() { _clearAllCache_impl() }

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
        requestedUserIds = []
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
        pendingChatInfoRequests = []

        pendingCleanupTimer?.invalidate()
        pendingCleanupTimer = nil

        historyJobs = [:]
        reachedHistoryStart = []
        historyWindowLimitByChatId = [:]
        historyGenerationByChatId = [:]
        historyRequestStartedAtNs = [:]
        historyMetrics = HistoryMetrics()

        didLoadInitialData = false
        didSendTdlibParameters = false
        didRequestInitialStorageStats = false

        viewMessagesCoordinator.resetAll()
        downloadLimiter.reset()
        Task { await messageStore.reset() }

        startPendingCleanupTimer()
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

    func enqueueTDLibRequest(_ req: [String: Any], typeOverride: String? = nil) {
        tdlibRequestQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            let queueLabel = String(cString: __dispatch_queue_get_label(nil))
            let type = typeOverride
                ?? (req["@type"] as? String)
                ?? "unknown"
            self.log.debug("tdlib request type=\(type, privacy: .public) queue=\(queueLabel, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
#endif
            if self.sendIfAuthorized(req, typeOverride: typeOverride) {
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
    private var pendingValue: Value?
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func schedule(value: Value, publish: @escaping @MainActor (Value) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pendingValue == value {
                return
            }
            self.pendingValue = value
            self.workItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let snapshot = self.pendingValue else { return }
                self.pendingValue = nil
                Task { @MainActor in
                    await Task.yield()
                    publish(snapshot)
                }
            }
            self.workItem = item
            self.queue.asyncAfter(deadline: .now() + self.delay, execute: item)
        }
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
    private var pendingByChat: [Int64: PendingState] = [:]
    private var seenByChat: [Int64: Set<Int64>] = [:]
    private var lastSentRangeByChat: [Int64: RangeSignature] = [:]

    init(debounceDelay: TimeInterval = 0.25) {
        self.debounceDelay = debounceDelay
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
        let range: RangeSignature? = {
            guard let min = minMessageId, let max = maxMessageId, min > 0, max > 0 else { return nil }
            return RangeSignature(minId: min, maxId: max)
        }()

        queue.async { [weak self] in
            guard let self else { return }
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
                send(chatId, ids)
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
    private struct ChatState {
        var messagesById: [Int64: TGMessage] = [:]
        var windowLimit: Int = 160
        var continuations: [UUID: AsyncStream<[TGMessage]>.Continuation] = [:]
        var lastPublishedSnapshot: [TGMessage] = []
        var publishTask: Task<Void, Never>?
    }

    private let log = Logger(subsystem: "com.aurora.app", category: "message.store")
    private let publishDebounceNs: UInt64
    private let maxMessagesPerChat: Int
    private let sortBias: Int64 = 9_000_000_000_000_000_000
    private var chatStateById: [Int64: ChatState] = [:]
    private var mutationCount = 0

    init(publishDebounceMs: UInt64 = 33, maxMessagesPerChat: Int = 6_000) {
        self.publishDebounceNs = publishDebounceMs * 1_000_000
        self.maxMessagesPerChat = maxMessagesPerChat
    }

    func subscribe(chatId: Int64, windowLimit: Int) -> AsyncStream<[TGMessage]> {
        let id = UUID()
        return AsyncStream<[TGMessage]> { continuation in
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
        let bounded = max(40, min(limit, 5_000))
        guard chat.windowLimit != bounded else { return }
        chat.windowLimit = bounded
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
        if let windowLimit {
            chat.windowLimit = max(chat.windowLimit, min(windowLimit, 5_000))
        }

        var changed = 0
        for message in messages where message.chatId == chatId {
            chat.messagesById[message.id] = message
            changed += 1
        }

        if changed > 0 {
            pruneIfNeeded(chat: &chat)
        }
        chatStateById[chatId] = chat
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
    func applyContent(chatId: Int64, messageId: Int64, text: String) async -> Bool {
        guard var chat = chatStateById[chatId],
              var message = chat.messagesById[messageId]
        else { return false }
        guard message.text != text else { return false }
        let id = message.id
        let date = message.date
        let isOutgoing = message.isOutgoing
        let senderUserId = message.senderUserId
        let contentType = message.contentType
        let rawText = message.rawText
        let entities = message.entities
        let sendState = message.sendState
        let replyToMessageId = message.replyToMessageId
        let localId = message.localId
        let sendingId = message.sendingId
        let editedAt = message.editedAt
        let canRetry = message.canRetry
        let retryCount = message.retryCount
        let nextRetryAt = message.nextRetryAt
        let newMessage = await MainActor.run {
            TGMessage(
                id: id,
                chatId: chatId,
                date: date,
                isOutgoing: isOutgoing,
                senderUserId: senderUserId,
                text: text,
                contentType: contentType,
                rawText: rawText,
                entities: entities,
                sendState: sendState,
                replyToMessageId: replyToMessageId,
                localId: localId,
                sendingId: sendingId,
                editedAt: editedAt,
                canRetry: canRetry,
                retryCount: retryCount,
                nextRetryAt: nextRetryAt
            )
        }
        message = newMessage
        chat.messagesById[messageId] = message
        chatStateById[chatId] = chat
        debugLogMutation(label: "content", chatId: chatId, changed: 1)
        schedulePublish(chatId: chatId)
        return true
    }

    @discardableResult
    func applyDelete(chatId: Int64, messageIds: [Int64]) -> Int {
        guard var chat = chatStateById[chatId], !messageIds.isEmpty else { return 0 }
        var removed = 0
        for id in messageIds {
            if chat.messagesById.removeValue(forKey: id) != nil {
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
    }

    private func attach(
        continuation: AsyncStream<[TGMessage]>.Continuation,
        chatId: Int64,
        subscriberId: UUID,
        windowLimit: Int
    ) {
        var chat = chatStateById[chatId] ?? ChatState()
        chat.windowLimit = max(chat.windowLimit, min(windowLimit, 5_000))
        chat.continuations[subscriberId] = continuation
        chatStateById[chatId] = chat
        continuation.yield(snapshot(for: chat))
    }

    private func detach(chatId: Int64, subscriberId: UUID) {
        guard var chat = chatStateById[chatId] else { return }
        chat.continuations.removeValue(forKey: subscriberId)
        chatStateById[chatId] = chat
    }

    private func schedulePublish(chatId: Int64) {
        guard var chat = chatStateById[chatId] else { return }
        chat.publishTask?.cancel()
        chat.publishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.publishDebounceNs)
            await self.publish(chatId: chatId)
        }
        chatStateById[chatId] = chat
    }

    private func publish(chatId: Int64) {
        guard var chat = chatStateById[chatId] else { return }
        chat.publishTask = nil
        let newSnapshot = snapshot(for: chat)
        guard newSnapshot != chat.lastPublishedSnapshot else {
            chatStateById[chatId] = chat
            return
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
        let sorted = chat.messagesById.values.sorted { lhs, rhs in
            let l = orderingKey(for: lhs.id)
            let r = orderingKey(for: rhs.id)
            if l == r {
                return lhs.date < rhs.date
            }
            return l < r
        }
        if sorted.count > chat.windowLimit {
            return Array(sorted.suffix(chat.windowLimit))
        }
        return sorted
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
        let sortedIds = chat.messagesById.keys.sorted { orderingKey(for: $0) < orderingKey(for: $1) }
        for id in sortedIds.prefix(overflow) {
            chat.messagesById.removeValue(forKey: id)
        }
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
