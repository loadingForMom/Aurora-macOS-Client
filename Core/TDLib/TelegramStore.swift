//  TelegramStore.swift
//  Aurora
//

import Foundation
import Combine
import AppKit

@MainActor
final class TelegramStore: ObservableObject {
    // TDLib
    let td = TDLibClient()

    // MARK: - Core published state

    @Published var authState: String = "unknown"
    @Published var chatsById: [Int64: TGChat] = [:]
    @Published var usersById: [Int64: TGUser] = [:]
    @Published var messagesByChatId: [Int64: [TGMessage]] = [:]

    @Published var selectedChatId: Int64?
    @Published var isLoadingHistory: Bool = false

    @Published var logs: [String] = []
    @Published var showLogs: Bool = false

    // MARK: - App DB

    var database: AppDatabase? = nil
    var databaseRepository: AppDatabaseRepository? = nil
    @Published var lastDatabaseStats: DatabaseStats?

    // MARK: - Storage / Cache (Settings)

    @Published var storageByFileType: [StorageFileTypeStat] = []
    @Published var storageTotalBytes: Int64 = 0
    @Published var storageLastRefreshedAt: Date? = nil
    @Published var cacheLimitBytes: Int64 = 2_147_483_648 // 2 GB default

    let cacheLimitBytesKey = "aurora.cache_limit_bytes"
    var storageExtrasInFlight: Set<String> = []
    var didRequestInitialStorageStats = false

    // MARK: - Current user (Settings header)

    @Published var myUserId: Int64?
    @Published var myProfilePhotoPath: String?

    // MARK: - Chat avatars (paths)

    @Published var chatAvatarPathByChatId: [Int64: String] = [:]

    struct ChatAvatarMeta {
        var smallFileId: Int32?
        var bigFileId: Int32?
        var smallPath: String?
        var bigPath: String?
    }

    var chatAvatarMetaByChatId: [Int64: ChatAvatarMeta] = [:]
    var chatIdByAvatarFileId: [Int32: Int64] = [:]
    var requestedAvatarFileIds: Set<Int32> = []

    var myPhotoFileId: Int32?

    // MARK: - JSON parsing cache

    var lastParsedUpdate: String?
    var lastParsedObject: [String: Any]?

    // MARK: - Thumbnail cache

    let imageMemCache = NSCache<NSString, NSImage>()
    let thumbsDirURL: URL

    let defaultListThumbMaxPx: Int = 128
    let defaultProfileThumbMaxPx: Int = 128
    let defaultInspectorThumbMaxPx: Int = 1024
    let defaultPosterThumbMaxPx: Int = 2048

    // MARK: - Boot flags

    var didLoadInitialData = false
    var didSendTdlibParameters = false

    // MARK: - Optimistic sending infra

    struct PendingLink {
        let chatId: Int64
        var placeholderId: Int64
        let localId: UUID
        let sendingId: Int32
        let text: String
        let date: Int
    }

    var pendingByLocalId: [UUID: PendingLink] = [:]
    var localIdBySendingId: [Int32: UUID] = [:]
    var localIdByTempMessageId: [Int64: UUID] = [:]
    var nextLocalTempId: Int64 = -1

    // MARK: - History jobs

    enum HistoryJobKind { case latest, older }

    struct HistoryJob {
        let chatId: Int64
        let targetCount: Int
        var nextFromMessageId: Int64
        var accById: [Int64: TGMessage]
        let kind: HistoryJobKind
    }

    var historyJobs: [String: HistoryJob] = [:]
    var reachedHistoryStart: Set<Int64> = []

    // MARK: - Init

    init() {
        // Thumbs directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aurora/thumbs", isDirectory: true)
        thumbsDirURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        imageMemCache.countLimit = 256

        if let n = UserDefaults.standard.object(forKey: cacheLimitBytesKey) as? NSNumber {
            cacheLimitBytes = n.int64Value
        }

        // ✅ СНАЧАЛА DB (до любых замыканий, где мелькает self)
        do {
            let db = try AppDatabase()
            database = db
            databaseRepository = AppDatabaseRepository(dbWriter: db.dbWriter)
        } catch {
            database = nil
            databaseRepository = nil
            print("[DB] Failed to initialize app database: \(error)")
        }

        // ✅ ПОТОМ event loop (тут создаются closures и захватывается self)
        td.startEventLoop(onUpdate: { [weak self] upd in
            Task { @MainActor in
                self?.pushLog(upd)
                self?.handleUpdate(upd)
            }
        }, onResponse: { [weak self] resp in
            Task { @MainActor in
                self?.pushLog(resp)
                self?.handleResponse(resp)
            }
        })

        td.send(#"{"@type":"getOption","name":"version"}"#)
    }
    // MARK: - Computed

    var sortedChats: [TGChat] {
        chatsById.values.sorted {
            if $0.order != $1.order { return $0.order > $1.order }
            if $0.lastMessageDate != $1.lastMessageDate { return $0.lastMessageDate > $1.lastMessageDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var myDisplayName: String {
        guard let id = myUserId else { return "" }
        return usersById[id]?.displayName ?? ""
    }

    var isAuthorized: Bool {
        authState == "authorizationStateReady"
    }

    // MARK: - Public API (UI calls)

    func selectChat(_ chatId: Int64, forceReload: Bool = false) {
        let isSame = (selectedChatId == chatId)
        if !isSame { selectedChatId = chatId }

        if !forceReload, let existing = messagesByChatId[chatId], !existing.isEmpty {
            return
        }
        loadLatestHistory(chatId: chatId)
    }

    func userDisplayName(_ userId: Int64?) -> String {
        guard let id = userId else { return "" }
        return usersById[id]?.displayName ?? "User \(id)"
    }

    // Read/viewed
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool = false) {
        guard !messageIds.isEmpty else { return }
        let req: [String: Any] = [
            "@type": "viewMessages",
            "chat_id": chatId,
            "message_ids": messageIds,
            "force_read": forceRead
        ]
        sendJSON(req)
    }

    func markChatAsReadToLatestIfNeeded(chatId: Int64) {
        guard let c = chatsById[chatId] else { return }
        if c.unreadCount <= 0 { return }
        if c.lastMessageId == 0 { return }
        viewMessages(chatId: chatId, messageIds: [c.lastMessageId], forceRead: true)
    }

    func printDatabaseStats() {
        guard let databaseRepository else {
            print("[DB] Database not initialized")
            return
        }
        let stats = databaseRepository.fetchStats()
        lastDatabaseStats = stats
        print("[DB] Stats chats=\(stats.chats) messages=\(stats.messages) users=\(stats.users)")
    }

    // MARK: - App DB helpers

    func persistChat(_ chat: TGChat) {
        databaseRepository?.upsertChat(chat)
    }

    func persistChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        databaseRepository?.upsertChatLastMessage(chatId: chatId, messageId: messageId, preview: preview, date: date)
    }

    func persistUser(_ user: TGUser) {
        databaseRepository?.upsertUser(user)
    }

    func persistMessage(_ message: TGMessage) {
        databaseRepository?.upsertMessage(message)
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) {
        databaseRepository?.deleteMessages(chatId: chatId, messageIds: messageIds)
    }

    // Messages actions (implemented in +OptimisticSending)
    func sendText(chatId: Int64, text: String) { _sendText_impl(chatId: chatId, text: text) }
    func retrySend(message: TGMessage) { _retrySend_impl(message: message) }
    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool = true) { _deleteMessages_impl(chatId: chatId, messageIds: messageIds, revoke: revoke) }
    func editMessageText(chatId: Int64, messageId: Int64, newText: String) { _editMessageText_impl(chatId: chatId, messageId: messageId, newText: newText) }

    // History paging (implemented in +History)
    func loadMoreHistory(chatId: Int64, pageSize: Int = 80) { _loadMoreHistory_impl(chatId: chatId, pageSize: pageSize) }

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

    // MARK: - Logging
    func pushLog(_ s: String) {
        logs.append(s)
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }

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
        chatsById = [:]
        usersById = [:]
        messagesByChatId = [:]
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
        nextLocalTempId = -1

        historyJobs = [:]
        reachedHistoryStart = []

        didLoadInitialData = false
        didSendTdlibParameters = false
        didRequestInitialStorageStats = false
    }
}
