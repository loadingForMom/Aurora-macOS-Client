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

    // MARK: - App DB

    var database: AppDatabase? = nil
    @Published var databaseRepository: AppDatabaseRepository? = nil
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
        let sendingId: Int32
        let text: String
        let date: Int
    }

    var pendingByLocalId: [UUID: PendingLink] = [:]
    var localIdBySendingId: [Int32: UUID] = [:]
    var localIdByTempMessageId: [Int64: UUID] = [:]
    var serverMessageIdByLocalId: [UUID: Int64] = [:]
    var nextLocalTempId: Int64 = -1

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
        td.startEventLoop(onUpdate: { [weak self] upd, obj in
            Task { @MainActor in
                self?.cacheParsedObject(json: upd, obj: obj)
                self?.pushLog(upd)
                self?.handleUpdate(upd)
            }
        }, onResponse: { [weak self] resp, obj in
            Task { @MainActor in
                self?.cacheParsedObject(json: resp, obj: obj)
                self?.pushLog(resp)
                self?.handleResponse(resp)
            }
        })

        td.send(#"{"@type":"getOption","name":"version"}"#)

        if let n = UserDefaults.standard.object(forKey: cacheLimitBytesKey) as? NSNumber {
            cacheLimitBytes = n.int64Value
        }
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
        loadInitialHistory(chatId: chatId)
    }

    func userDisplayName(_ userId: Int64?) -> String {
        guard let id = userId else { return "" }
        return usersById[id]?.displayName ?? "User \(id)"
    }

    // Read/viewed
    func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool = false) {
        let filteredIds = messageIds.filter { $0 > 0 }
#if DEBUG
        if filteredIds.count != messageIds.count {
            print("[TDLib][viewMessages] filtered invalid ids from \(messageIds)")
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

    private func cacheParsedObject(json: String, obj: [String: Any]?) {
        guard let obj else { return }
        lastParsedUpdate = json
        lastParsedObject = obj
#if DEBUG
        debugCachedParseCount += 1
        if debugCachedParseCount % debugCachedParseLogInterval == 0 {
            print("[TDLib][parse] cached objects injected=\(debugCachedParseCount)")
        }
#endif
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
        print("[UI] submitAuthCode \(code)")
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
        serverMessageIdByLocalId = [:]
        nextLocalTempId = -1

        historyJobs = [:]
        reachedHistoryStart = []
        historyWindowLimitByChatId = [:]
        historyGenerationByChatId = [:]

        didLoadInitialData = false
        didSendTdlibParameters = false
        didRequestInitialStorageStats = false
    }
}
