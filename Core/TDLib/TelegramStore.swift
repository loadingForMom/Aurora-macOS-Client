//
//  TelegramStore.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import Combine
import AppKit

@MainActor
final class TelegramStore: ObservableObject {
    private let td = TDLibClient()

    @Published var authState: String = "unknown"
    @Published var chatsById: [Int64: TGChat] = [:]
    @Published var usersById: [Int64: TGUser] = [:]
    @Published var messagesByChatId: [Int64: [TGMessage]] = [:]

    @Published var selectedChatId: Int64?
    @Published var isLoadingHistory: Bool = false

    @Published var logs: [String] = []
    @Published var showLogs: Bool = false

    // MARK: - Storage / Cache (for Settings)

    @Published var storageByFileType: [StorageFileTypeStat] = []
    @Published var storageTotalBytes: Int64 = 0
    @Published var storageLastRefreshedAt: Date? = nil
    @Published var cacheLimitBytes: Int64 = 2_147_483_648 // 2 GB default

    private let cacheLimitBytesKey = "aurora.cache_limit_bytes"
    private var storageExtrasInFlight: Set<String> = []
    private var didRequestInitialStorageStats = false

    // MARK: - Current user (for Settings sidebar header)

    @Published var myUserId: Int64?
    @Published var myProfilePhotoPath: String?

    // MARK: - Chat avatars (photo per chat)
    // Original paths (whatever TDLib gave us)
    @Published var chatAvatarPathByChatId: [Int64: String] = [:]

    // TDLib file ids for chat avatars (small / big)
    private struct ChatAvatarMeta {
        var smallFileId: Int32?
        var bigFileId: Int32?
        var smallPath: String?
        var bigPath: String?
    }
    private var chatAvatarMetaByChatId: [Int64: ChatAvatarMeta] = [:]

    // fileId -> chatId mapping (for updateFile)
    private var chatIdByAvatarFileId: [Int32: Int64] = [:]
    private var requestedAvatarFileIds: Set<Int32> = []

    // My photo file id
    private var myPhotoFileId: Int32?

    // MARK: - Thumbnail cache
    private let imageMemCache = NSCache<NSString, NSImage>()
    private let thumbsDirURL: URL
    private let defaultListThumbMaxPx: Int = 128
    private let defaultProfileThumbMaxPx: Int = 128
    // Inspector avatars are often displayed very large; 512px can look soft on Retina.
    private let defaultInspectorThumbMaxPx: Int = 1024
    // Poster/background avatar can be even larger.
    private let defaultPosterThumbMaxPx: Int = 2048

    private func screenScale() -> CGFloat {
        // Best-effort; UI sizes are in points.
        NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func maxPixel(forPointSize pt: CGFloat, clampTo maxClamp: Int) -> Int {
        let px = Int((pt * screenScale()).rounded(.up))
        return min(max(32, px), maxClamp)
    }

    // MARK: - TDLib boot flags
    private var didLoadInitialData = false
    private var didSendTdlibParameters = false

    // MARK: - Optimistic sending infra

    private struct PendingLink {
        let chatId: Int64
        var placeholderId: Int64
        let localId: UUID
        let sendingId: Int32
        let text: String
        let date: Int
    }

    /// localId -> pending link (placeholder bookkeeping)
    private var pendingByLocalId: [UUID: PendingLink] = [:]

    /// sendingId -> localId (stable matching with TDLib pending messages)
    private var localIdBySendingId: [Int32: UUID] = [:]

    /// TDLib temp message id (old_message_id) -> localId (so sendSucceeded can clean up)
    private var localIdByTempMessageId: [Int64: UUID] = [:]

    /// Our own placeholder message ids (negative, unique)
    private var nextLocalTempId: Int64 = -1

    private func makeLocalTempId() -> Int64 {
        nextLocalTempId -= 1
        return nextLocalTempId
    }

    private func makeSendingId() -> Int32 {
        var x: Int32 = Int32.random(in: 1...Int32.max)
        while localIdBySendingId[x] != nil {
            x = Int32.random(in: 1...Int32.max)
        }
        return x
    }

    // MARK: - History jobs

    private enum HistoryJobKind { case latest, older }

    private struct HistoryJob {
        let chatId: Int64
        let targetCount: Int
        var nextFromMessageId: Int64
        var accById: [Int64: TGMessage]
        let kind: HistoryJobKind
    }

    private var historyJobs: [String: HistoryJob] = [:]
    private var reachedHistoryStart: Set<Int64> = []

    init() {
        // Thumbs directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aurora/thumbs", isDirectory: true)
        thumbsDirURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        imageMemCache.countLimit = 256

        td.startReceiveLoop { [weak self] upd in
            Task { @MainActor in
                self?.pushLog(upd)
                self?.handleUpdate(upd)
            }
        }

        td.send(#"{"@type":"getOption","name":"version"}"#)

        if let n = UserDefaults.standard.object(forKey: cacheLimitBytesKey) as? NSNumber {
            cacheLimitBytes = n.int64Value
        }
    }

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

    /// Default for Settings sidebar header (~36pt)
    var myProfileNSImage: NSImage? {
        myProfileNSImage(pointSize: 36)
    }

    func myProfileNSImage(pointSize: CGFloat) -> NSImage? {
        guard let src = myProfilePhotoPath, !src.isEmpty else { return nil }
        let maxPx = maxPixel(forPointSize: pointSize, clampTo: defaultProfileThumbMaxPx)
        return loadOrMakeThumbNSImage(sourcePath: src,
                                      fileId: myPhotoFileId,
                                      kind: "me",
                                      maxPixel: maxPx,
                                      jpegQuality: 0.92)
    }

    /// For chat list / header etc.
    func chatAvatarNSImage(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool = false,
        maxClamp: Int? = nil,
        kindOverride: String? = nil
    ) -> NSImage? {
        let cap = maxClamp ?? (preferHiRes ? defaultInspectorThumbMaxPx : defaultListThumbMaxPx)
        let maxPx = maxPixel(forPointSize: pointSize, clampTo: cap)

        // Pick best available source path
        let meta = chatAvatarMetaByChatId[chatId]
        let src: String? = {
            if preferHiRes {
                if let p = meta?.bigPath, !p.isEmpty { return p }
                if let p = meta?.smallPath, !p.isEmpty { return p }
                return chatAvatarPathByChatId[chatId]
            } else {
                if let p = meta?.smallPath, !p.isEmpty { return p }
                if let p = meta?.bigPath, !p.isEmpty { return p }
                return chatAvatarPathByChatId[chatId]
            }
        }()

        guard let srcPath = src, !srcPath.isEmpty else { return nil }

        // Choose fileId (helps stable thumb naming)
        let fid: Int32? = {
            if preferHiRes { return meta?.bigFileId ?? meta?.smallFileId }
            return meta?.smallFileId ?? meta?.bigFileId
        }()

        let kind = kindOverride ?? (preferHiRes ? "chat_big" : "chat_small")
        let q: CGFloat = preferHiRes ? 0.92 : 0.88

        return loadOrMakeThumbNSImage(
            sourcePath: srcPath,
            fileId: fid,
            kind: kind,
            maxPixel: maxPx,
            jpegQuality: q
        )
    }

    /// Call when opening inspector so we can fetch the bigger avatar if TDLib has it.
    func prefetchChatAvatarHiResIfNeeded(chatId: Int64) {
        guard let meta = chatAvatarMetaByChatId[chatId] else { return }
        guard let bigId = meta.bigFileId else { return }

        // If we already have a usable big path, generate both inspector + poster thumbs.
        if let p = meta.bigPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            _ = loadOrMakeThumbNSImage(
                sourcePath: p,
                fileId: bigId,
                kind: "chat_big",
                maxPixel: defaultInspectorThumbMaxPx,
                jpegQuality: 0.92
            )

            _ = loadOrMakeThumbNSImage(
                sourcePath: p,
                fileId: bigId,
                kind: "chat_poster",
                maxPixel: defaultPosterThumbMaxPx,
                jpegQuality: 0.92
            )
            return
        }

        downloadFileIfNeeded(fileId: bigId, priority: 10)
    }

    // MARK: - Read / viewed helpers

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

    /// Legacy helper if some UI still passes path around (kept as-is).
    func chatAvatarNSImage(chatId: Int64) -> NSImage? {
        // Default small usage; better to call the size-aware variant.
        chatAvatarNSImage(chatId: chatId, pointSize: 40, preferHiRes: false)
    }

    func userDisplayName(_ userId: Int64?) -> String {
        guard let id = userId else { return "" }
        return usersById[id]?.displayName ?? "User \(id)"
    }

    func selectChat(_ chatId: Int64, forceReload: Bool = false) {
        let isSame = (selectedChatId == chatId)
        if !isSame {
            selectedChatId = chatId
        }

        if !forceReload, let existing = messagesByChatId[chatId], !existing.isEmpty {
            return
        }

        loadLatestHistory(chatId: chatId)
    }

    // MARK: - Public message actions (send / retry / edit / delete)

    func sendText(chatId: Int64, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let now = Int(Date().timeIntervalSince1970)
        let localId = UUID()
        let sendingId = makeSendingId()
        let placeholderId = makeLocalTempId()

        let pending = TGMessage(
            id: placeholderId,
            chatId: chatId,
            date: now,
            isOutgoing: true,
            senderUserId: myUserId,
            text: clean,
            sendState: .pending,
            localId: localId,
            sendingId: sendingId,
            editedAt: nil,
            canRetry: false
        )

        optimisticInsertMessage(pending)

        pendingByLocalId[localId] = PendingLink(
            chatId: chatId,
            placeholderId: placeholderId,
            localId: localId,
            sendingId: sendingId,
            text: clean,
            date: now
        )
        localIdBySendingId[sendingId] = localId

        let options: [String: Any] = [
            "@type": "messageSendOptions",
            "disable_notification": false,
            "from_background": false,
            "protect_content": false,
            "update_order_of_installed_sticker_sets": false,
            "scheduling_state": NSNull(),
            "sending_id": Int(sendingId),
            "only_preview": false
        ]

        let req: [String: Any] = [
            "@type": "sendMessage",
            "@extra": "send:\(localId.uuidString)",
            "chat_id": chatId,
            "message_thread_id": 0,
            "reply_to": NSNull(),
            "options": options,
            "reply_markup": NSNull(),
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": clean,
                    "entities": []
                ],
                "clear_draft": true
            ]
        ]
        sendJSON(req)
    }

    func retrySend(message: TGMessage) {
        guard message.chatId != 0 else { return }

        if message.canRetry, message.id != 0 {
            markMessagePending(chatId: message.chatId, id: message.id)

            let req: [String: Any] = [
                "@type": "resendMessages",
                "@extra": "resend:\(message.chatId):\(message.id):\(UUID().uuidString)",
                "chat_id": message.chatId,
                "message_ids": [message.id]
            ]
            sendJSON(req)
            return
        }

        sendText(chatId: message.chatId, text: message.text)
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool = true) {
        guard !messageIds.isEmpty else { return }
        let req: [String: Any] = [
            "@type": "deleteMessages",
            "@extra": "delete:\(chatId):\(UUID().uuidString)",
            "chat_id": chatId,
            "message_ids": messageIds,
            "revoke": revoke
        ]
        sendJSON(req)
    }

    func editMessageText(chatId: Int64, messageId: Int64, newText: String) {
        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let req: [String: Any] = [
            "@type": "editMessageText",
            "@extra": "edit:\(chatId):\(messageId):\(UUID().uuidString)",
            "chat_id": chatId,
            "message_id": messageId,
            "reply_markup": NSNull(),
            "input_message_content": [
                "@type": "inputMessageText",
                "text": [
                    "@type": "formattedText",
                    "text": clean,
                    "entities": []
                ],
                "clear_draft": false
            ]
        ]
        sendJSON(req)
    }

    // MARK: - TDLib parameters

    private func sendTdlibParametersIfPossible() -> Bool {
        let apiId = Config.apiId
        let apiHash = Config.apiHash
        guard apiId != 0, !apiHash.isEmpty else {
            print("Missing TELEGRAM_API_ID / TELEGRAM_API_HASH in Config.swift")
            return false
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("Aurora/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let req: [String: Any] = [
            "@type": "setTdlibParameters",
            "database_directory": dbDir.path,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": apiId,
            "api_hash": apiHash,
            "system_language_code": "en",
            "device_model": "Mac",
            "system_version": "macOS",
            "application_version": "0.2",
            "enable_storage_optimizer": true
        ]
        sendJSON(req)
        return true
    }

    // MARK: - History

    private func loadLatestHistory(chatId: Int64) {
        isLoadingHistory = (selectedChatId == chatId)
        reachedHistoryStart.remove(chatId)

        messagesByChatId[chatId] = []
        cancelHistoryJobs(for: chatId)

        let extra = "history:\(chatId):latest:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            targetCount: 160,
            nextFromMessageId: 0,
            accById: [:],
            kind: .latest
        )
        sendChatHistory(chatId: chatId, fromMessageId: 0, offset: 0, limit: 100, extra: extra)
    }

    private func cancelHistoryJobs(for chatId: Int64) {
        let keys = historyJobs.compactMap { (k, v) in v.chatId == chatId ? k : nil }
        for k in keys { historyJobs.removeValue(forKey: k) }
    }

    private func sendChatHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int, extra: String) {
        let req: [String: Any] = [
            "@type": "getChatHistory",
            "@extra": extra,
            "chat_id": chatId,
            "from_message_id": fromMessageId,
            "offset": offset,
            "limit": limit,
            "only_local": false
        ]
        sendJSON(req)
    }

    /// Lazy paging: call this when the user scrolls to the top of the messages list.
    func loadMoreHistory(chatId: Int64, pageSize: Int = 80) {
        if isLoadingHistory { return }
        if reachedHistoryStart.contains(chatId) { return }

        guard let current = messagesByChatId[chatId], !current.isEmpty else {
            loadLatestHistory(chatId: chatId)
            return
        }

        if current.count >= 800 { return }

        isLoadingHistory = (selectedChatId == chatId)

        let serverMsgs = current.filter { $0.id > 0 }
        guard let oldestServerId = serverMsgs.min(by: { $0.id < $1.id })?.id else {
            isLoadingHistory = false
            return
        }

        let target = min(800, current.count + pageSize)
        let extra = "history:\(chatId):older:\(UUID().uuidString)"

        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            targetCount: target,
            nextFromMessageId: oldestServerId,
            accById: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) }),
            kind: .older
        )

        sendChatHistory(chatId: chatId, fromMessageId: oldestServerId, offset: 0, limit: pageSize, extra: extra)
    }

    // MARK: - Storage / Cache (Settings helpers)

    func refreshStorageStatistics() {
        let extra = "storage:full:\(UUID().uuidString)"
        storageExtrasInFlight.insert(extra)

        let req: [String: Any] = [
            "@type": "getStorageStatistics",
            "@extra": extra,
            "chat_limit": 0
        ]
        sendJSON(req)
    }

    func applyCacheLimitBytes(_ bytes: Int64) {
        let clamped = max(0, bytes)
        cacheLimitBytes = clamped
        UserDefaults.standard.set(NSNumber(value: clamped), forKey: cacheLimitBytesKey)
        optimizeStorage(maxBytes: clamped)
    }

    func clearAllCache() {
        optimizeStorage(maxBytes: 0)
    }

    private func optimizeStorage(maxBytes: Int64) {
        let extra = "storage:optimize:\(UUID().uuidString)"
        storageExtrasInFlight.insert(extra)

        let fileTypes: [[String: Any]] = [
            ["@type": "fileTypePhoto"],
            ["@type": "fileTypeVideo"],
            ["@type": "fileTypeAnimation"],
            ["@type": "fileTypeDocument"],
            ["@type": "fileTypeAudio"],
            ["@type": "fileTypeVoiceNote"],
            ["@type": "fileTypeVideoNote"],
            ["@type": "fileTypeSticker"],
            ["@type": "fileTypeWallpaper"],
            ["@type": "fileTypeProfilePhoto"],
            ["@type": "fileTypeThumbnail"],
            ["@type": "fileTypeTemp"],
            ["@type": "fileTypeUnknown"]
        ]

        let req: [String: Any] = [
            "@type": "optimizeStorage",
            "@extra": extra,
            "size": maxBytes,
            "ttl": 0,
            "count": 0,
            "immunity_delay": 0,
            "file_types": fileTypes,
            "chat_ids": [],
            "exclude_chat_ids": [],
            "return_deleted_file_statistics": false,
            "chat_limit": 0
        ]

        sendJSON(req)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStorageStatistics()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshStorageStatistics()
        }
    }

    private struct ParsedStorageStatistics {
        let extra: String?
        let byFileType: [StorageFileTypeStat]
    }

    private func parseStorageStatisticsAny(_ upd: String) -> ParsedStorageStatistics? {
        guard let obj = parseJSON(upd) else { return nil }
        guard let type = obj["@type"] as? String else { return nil }

        let extra = obj["@extra"] as? String

        if type == "error" {
            if let extra { storageExtrasInFlight.remove(extra) }
            return nil
        }

        if type == "ok" {
            if let extra { storageExtrasInFlight.remove(extra) }
            return nil
        }

        func extraIsAcceptableForStorage() -> Bool {
            if storageExtrasInFlight.isEmpty { return true }
            guard let extra else { return true }
            return storageExtrasInFlight.contains(extra)
        }

        if type == "storageStatisticsFast" {
            guard extraIsAcceptableForStorage() else { return nil }

            let files = (obj["files_size"] as? NSNumber)?.int64Value ?? 0
            let db = (obj["database_size"] as? NSNumber)?.int64Value ?? 0
            let lpdb = (obj["language_pack_database_size"] as? NSNumber)?.int64Value ?? 0
            let log = (obj["log_size"] as? NSNumber)?.int64Value ?? 0

            let stats: [StorageFileTypeStat] = [
                StorageFileTypeStat(fileTypeKey: "fastFiles", bytes: files, count: 0),
                StorageFileTypeStat(fileTypeKey: "fastDatabase", bytes: db, count: 0),
                StorageFileTypeStat(fileTypeKey: "fastLanguagePackDatabase", bytes: lpdb, count: 0),
                StorageFileTypeStat(fileTypeKey: "fastLog", bytes: log, count: 0)
            ].filter { $0.bytes > 0 }

            return ParsedStorageStatistics(extra: extra, byFileType: mergeAndSortStorage(stats))
        }

        if type == "storageStatistics" {
            guard extraIsAcceptableForStorage() else { return nil }

            let byChatAny = (obj["by_chat"] as? [Any]) ?? []
            let byChat = byChatAny.compactMap { $0 as? [String: Any] }

            var acc: [String: StorageFileTypeStat] = [:]
            for c in byChat {
                let byTypeAny = (c["by_file_type"] as? [Any]) ?? []
                let byType = byTypeAny
                    .compactMap { $0 as? [String: Any] }
                    .compactMap(parseStorageByFileType(_:))
                for s in byType {
                    acc[s.fileTypeKey] = (acc[s.fileTypeKey] ?? s).adding(bytes: s.bytes, count: s.count)
                }
            }

            return ParsedStorageStatistics(extra: extra, byFileType: mergeAndSortStorage(Array(acc.values)))
        }

        return nil
    }

    private func applyStorageStatistics(_ parsed: ParsedStorageStatistics) {
        if let extra = parsed.extra {
            storageExtrasInFlight.remove(extra)
        }

        storageByFileType = parsed.byFileType
        storageTotalBytes = parsed.byFileType.reduce(0) { $0 + $1.bytes }
        storageLastRefreshedAt = Date()
    }

    private func parseStorageByFileType(_ obj: [String: Any]) -> StorageFileTypeStat? {
        guard let ft = obj["file_type"] as? [String: Any],
              let ftType = ft["@type"] as? String else { return nil }

        let bytes = (obj["size"] as? NSNumber)?.int64Value ?? 0
        let count = (obj["count"] as? NSNumber)?.int32Value ?? 0

        return StorageFileTypeStat(fileTypeKey: ftType, bytes: bytes, count: count)
    }

    private func mergeAndSortStorage(_ stats: [StorageFileTypeStat]) -> [StorageFileTypeStat] {
        var acc: [String: StorageFileTypeStat] = [:]
        for s in stats {
            acc[s.fileTypeKey] = (acc[s.fileTypeKey] ?? s).adding(bytes: s.bytes, count: s.count)
        }
        return acc.values.sorted { $0.bytes > $1.bytes }
    }

    struct StorageFileTypeStat: Identifiable, Hashable {
        let fileTypeKey: String
        let bytes: Int64
        let count: Int32

        var id: String { fileTypeKey }

        var title: String {
            switch fileTypeKey {
            case "fastFiles": return "Кэш"
            case "fastDatabase": return "База данных"
            case "fastLanguagePackDatabase": return "Языки"
            case "fastLog": return "Логи"
            case "fileTypeVideo", "fileTypeVideoNote", "fileTypeAnimation": return "Видео"
            case "fileTypePhoto": return "Фото"
            case "fileTypeSticker": return "Стикеры"
            case "fileTypeAudio": return "Музыка"
            case "fileTypeVoiceNote": return "Спикеры"
            case "fileTypeDocument": return "Файлы"
            case "fileTypeProfilePhoto": return "Аватары"
            case "fileTypeThumbnail": return "Миниатюры"
            case "fileTypeWallpaper": return "Обои"
            case "fileTypeTemp": return "Временные"
            case "fileTypeDatabase": return "База сообщений"
            case "fileTypeUnknown": return "Кэш (всего)"
            default: return "Другое"
            }
        }

        var humanBytes: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        func adding(bytes addBytes: Int64, count addCount: Int32) -> StorageFileTypeStat {
            StorageFileTypeStat(fileTypeKey: fileTypeKey, bytes: self.bytes + addBytes, count: self.count + addCount)
        }
    }

    struct StorageBucket: Identifiable, Hashable {
        let title: String
        let bytes: Int64

        var id: String { title }

        var humanBytes: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    var storageBuckets: [StorageBucket] {
        var acc: [String: Int64] = [:]

        func bucketTitle(for fileTypeKey: String) -> String {
            switch fileTypeKey {
            case "fastFiles": return "Кэш"
            case "fastDatabase": return "База данных"
            case "fastLanguagePackDatabase": return "Языки"
            case "fastLog": return "Логи"
            case "fileTypeVideo", "fileTypeVideoNote", "fileTypeAnimation": return "Видео"
            case "fileTypePhoto": return "Фото"
            case "fileTypeAudio": return "Музыка"
            case "fileTypeVoiceNote": return "Спикеры"
            case "fileTypeSticker": return "Стикеры"
            case "fileTypeThumbnail", "fileTypeProfilePhoto", "fileTypeWallpaper": return "Прочее"
            case "fileTypeDatabase": return "База сообщений"
            case "fileTypeUnknown": return "Кэш (всего)"
            case "fileTypeTemp": return "Прочее"
            default: return "Другое"
            }
        }

        for s in storageByFileType {
            let t = bucketTitle(for: s.fileTypeKey)
            acc[t, default: 0] += s.bytes
        }

        return acc
            .map { StorageBucket(title: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    var clearableCacheBytes: Int64 {
        if let fast = storageByFileType.first(where: { $0.fileTypeKey == "fastFiles" }) {
            return fast.bytes
        }
        return storageTotalBytes
    }

    // MARK: - Update processing

    private func handleUpdate(_ upd: String) {
        if let st = parseAuthState(from: upd) {
            authState = st
        }

        if let (chatId, lastMessageId, preview, date) = parseUpdateChatLastMessage(upd) {
            applyChatLastMessageUpdate(chatId: chatId, lastMessageId: lastMessageId, preview: preview, date: date)
            keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        }

        if let (chatId, lastReadInboxMessageId, unreadCount) = parseUpdateChatReadInbox(upd) {
            applyChatReadInboxUpdate(chatId: chatId, lastReadInboxMessageId: lastReadInboxMessageId, unreadCount: unreadCount)
        }

        if authState == "authorizationStateWaitTdlibParameters", !didSendTdlibParameters {
            if sendTdlibParametersIfPossible() {
                didSendTdlibParameters = true
            }
        }

        if authState == "authorizationStateReady", !didLoadInitialData {
            didLoadInitialData = true
            td.send(#"{"@type":"getMe","@extra":"getMe"}"#)
            td.send(#"{"@type":"getChats","limit":200}"#)
        }

        if authState == "authorizationStateReady", !didRequestInitialStorageStats {
            didRequestInitialStorageStats = true
            refreshStorageStatistics()
        }

        if let ids = parseChatsResponse(upd) {
            for id in ids {
                td.send(#"{"@type":"getChat","chat_id":\#(id)}"#)
            }
        }

        if let (chat, smallId, bigId, bestPath) = parseChatObject(upd) {
            chatsById[chat.id] = chat

            if let p = bestPath {
                chatAvatarPathByChatId[chat.id] = p
            }

            registerChatAvatar(chatId: chat.id, smallFileId: smallId, bigFileId: bigId, initialBestPath: bestPath)

            if selectedChatId == nil {
                selectedChatId = chat.id
                loadLatestHistory(chatId: chat.id)
            }
        }

        if let (id, title) = parseUpdateChatTitle(upd) {
            if var c = chatsById[id] { c.title = title; chatsById[id] = c }
        }

        if let (chatId, order) = parseUpdateChatPosition(upd) {
            if var c = chatsById[chatId] { c.order = order; chatsById[chatId] = c }
        }

        // MARK: - Current user (me) + profile photo

        if let (me, photoFileId, photoPath) = parseMeUserResponse(upd) {
            myUserId = me.id
            usersById[me.id] = me

            if let p = photoPath {
                myProfilePhotoPath = p
            }

            if let fid = photoFileId {
                myPhotoFileId = fid
                downloadMyPhotoIfNeeded(fileId: fid)
            }
        }

        if let (u, photoFileId, photoPath) = parseUpdateUser(upt: upd) {
            usersById[u.id] = u

            if let meId = myUserId, meId == u.id {
                if let p = photoPath {
                    myProfilePhotoPath = p
                }
                if let fid = photoFileId {
                    myPhotoFileId = fid
                    downloadMyPhotoIfNeeded(fileId: fid)
                }
            }
        }

        if let path = parseUpdateFilePathIfMyPhoto(upd) {
            myProfilePhotoPath = path
            // Pre-generate a reasonable thumb once (won't redo on next launch because of mtime naming)
            _ = myProfileNSImage(pointSize: 36)
        }

        if let (chatId, fileId, path) = parseUpdateFilePathIfChatAvatar(upd) {
            applyChatAvatarFileUpdate(chatId: chatId, fileId: fileId, path: path)
        }

        if let (chatId, smallId, bigId, bestPath) = parseUpdateChatPhoto(upd) {
            if let p = bestPath {
                chatAvatarPathByChatId[chatId] = p
            }
            registerChatAvatar(chatId: chatId, smallFileId: smallId, bigFileId: bigId, initialBestPath: bestPath)
        }

        if let user = parseUserObject(upd) {
            usersById[user.id] = user
        }

        if let storage = parseStorageStatisticsAny(upd) {
            applyStorageStatistics(storage)
        }

        // MARK: - Response to sendMessage/editMessageText (responses can include @extra; updates do not)
        if let msgResponse = parseMessageFunctionResponse(upd) {
            handleFunctionResponseMessage(msgResponse)
        }

        // MARK: - Sending lifecycle updates
        if let succ = parseUpdateMessageSendSucceeded(upd) {
            handleSendSucceeded(succ)
        }

        if let fail = parseUpdateMessageSendFailed(upd) {
            handleSendFailed(fail)
        }

        // MARK: - Edit / content changes
        if let edited = parseUpdateMessageEdited(upd) {
            applyMessageEdited(chatId: edited.chatId, messageId: edited.messageId, editDate: edited.editDate)
        }

        if let content = parseUpdateMessageContent(upd) {
            applyMessageContentChanged(chatId: content.chatId, messageId: content.messageId, newContent: content.newContent)
        }

        // MARK: - Deletions
        if let del = parseUpdateDeleteMessages(upd) {
            applyMessagesDeleted(chatId: del.chatId, messageIds: del.messageIds)
        }

        // MARK: - History responses
        if let res = parseMessagesResponse(upd), var job = historyJobs[res.extra] {
            for m in res.messages {
                job.accById[m.id] = m
                requestUserIfNeeded(m.senderUserId)
            }

            if let oldest = res.messages.min(by: { $0.id < $1.id })?.id {
                job.nextFromMessageId = oldest
            }

            let currentCount = job.accById.count
            let remaining = max(0, job.targetCount - currentCount)

            if remaining == 0 || res.messages.isEmpty {
                if job.kind == .older && res.messages.isEmpty {
                    reachedHistoryStart.insert(job.chatId)
                }

                let ordered = sortChronological(Array(job.accById.values))
                messagesByChatId[job.chatId] = Array(ordered.suffix(job.targetCount))

                historyJobs.removeValue(forKey: res.extra)
                if selectedChatId == job.chatId {
                    isLoadingHistory = historyJobs.values.contains(where: { $0.chatId == job.chatId })
                }
            } else {
                historyJobs[res.extra] = job
                if selectedChatId == job.chatId {
                    let ordered = sortChronological(Array(job.accById.values))
                    let cap = min(job.targetCount, ordered.count)
                    messagesByChatId[job.chatId] = Array(ordered.suffix(cap))
                }
                sendChatHistory(chatId: job.chatId,
                                fromMessageId: job.nextFromMessageId,
                                offset: 0,
                                limit: min(remaining, 100),
                                extra: res.extra)
            }
        }

        // MARK: - New messages
        if let (chatId, msg) = parseUpdateNewMessage(upd) {
            requestUserIfNeeded(msg.senderUserId)

            if tryReconcileOutgoingPendingMessage(msg) {
                // Reconciled: do not append
            } else {
                appendMessage(msg, chatId: chatId)
            }

            updateChatLastFromLocalTimeline(chatId: chatId)
        }
    }

    // MARK: - Avatar apply / download

    private func registerChatAvatar(chatId: Int64, smallFileId: Int32?, bigFileId: Int32?, initialBestPath: String?) {
        var meta = chatAvatarMetaByChatId[chatId] ?? ChatAvatarMeta()
        meta.smallFileId = smallFileId
        meta.bigFileId = bigFileId

        // If we already have a path (from parse), try to attribute it.
        if let p = initialBestPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            // Heuristic: prefer small slot if exists.
            if meta.smallPath == nil {
                meta.smallPath = p
            } else if meta.bigPath == nil {
                meta.bigPath = p
            }
        }

        chatAvatarMetaByChatId[chatId] = meta

        if let sid = smallFileId {
            chatIdByAvatarFileId[sid] = chatId
            downloadFileIfNeeded(fileId: sid, priority: 16) // always fetch small
        }

        if let bid = bigFileId {
            chatIdByAvatarFileId[bid] = chatId
            // do NOT auto-download big; we do it on inspector open
        }
    }

    private func applyChatAvatarFileUpdate(chatId: Int64, fileId: Int32, path: String) {
        var meta = chatAvatarMetaByChatId[chatId] ?? ChatAvatarMeta()

        if meta.smallFileId == fileId {
            meta.smallPath = path
        } else if meta.bigFileId == fileId {
            meta.bigPath = path
        } else {
            // Unknown which; just store as best known
            if meta.smallPath == nil { meta.smallPath = path }
            else if meta.bigPath == nil { meta.bigPath = path }
        }

        chatAvatarMetaByChatId[chatId] = meta

        // Prefer small for general UI
        let best = (meta.smallPath?.isEmpty == false ? meta.smallPath : meta.bigPath)
        if let best, !best.isEmpty {
            chatAvatarPathByChatId[chatId] = best
        }

        // Pre-generate thumbs lazily:
        // - always generate the small/list thumb (cheap and future-proof)
        // - if this is the big avatar file, also generate inspector + poster thumbs
        let isBig = (meta.bigFileId == fileId)

        _ = loadOrMakeThumbNSImage(
            sourcePath: path,
            fileId: fileId,
            kind: isBig ? "chat_big" : "chat_small",
            maxPixel: isBig ? defaultInspectorThumbMaxPx : defaultListThumbMaxPx,
            jpegQuality: isBig ? 0.94 : 0.88
        )

        if isBig {
            _ = loadOrMakeThumbNSImage(
                sourcePath: path,
                fileId: fileId,
                kind: "chat_poster",
                maxPixel: defaultPosterThumbMaxPx,
                jpegQuality: 0.95
            )
        }

        // IMPORTANT: chatAvatarMetaByChatId is not @Published.
        // If only the big avatar updated, SwiftUI might not redraw unless we poke it.
        objectWillChange.send()
    }

    private func downloadFileIfNeeded(fileId: Int32, priority: Int) {
        if requestedAvatarFileIds.contains(fileId) { return }
        requestedAvatarFileIds.insert(fileId)

        let req: [String: Any] = [
            "@type": "downloadFile",
            "file_id": fileId,
            "priority": priority,
            "offset": 0,
            "limit": 0,
            "synchronous": false
        ]
        sendJSON(req)
    }

    // MARK: - Thumbnail load/make

    private func loadOrMakeThumbNSImage(sourcePath: String,
                                        fileId: Int32?,
                                        kind: String,
                                        maxPixel: Int,
                                        jpegQuality: CGFloat) -> NSImage? {
        guard !sourcePath.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: sourcePath) else { return nil }

        // Key includes maxPixel because same source can have multiple sizes.
        let memKey = "\(sourcePath)|\(kind)|\(maxPixel)" as NSString
        if let cached = imageMemCache.object(forKey: memKey) {
            return cached
        }

        let fid = fileId ?? stableThumbFallbackFileId(
            sourcePath: sourcePath,
            kind: kind,
            maxPixel: maxPixel
        )

        guard let thumbPath = AuroraImageThumb.ensureThumbnail(
            sourcePath: sourcePath,
            cacheDirURL: thumbsDirURL,
            fileId: fid,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: jpegQuality
        ) else {
            // fallback: still avoid “load full” if possible by ImageIO thumb -> NSImage
            if let img = AuroraImageThumb.decodeThumbnailNSImage(sourcePath: sourcePath, maxPixel: maxPixel) {
                imageMemCache.setObject(img, forKey: memKey)
                return img
            }
            return nil
        }

        // Load thumb (small file), cache in memory.
        if let img = NSImage(contentsOfFile: thumbPath) {
            imageMemCache.setObject(img, forKey: memKey)
            return img
        }

        // Last-resort decode
        if let img = AuroraImageThumb.decodeThumbnailNSImage(sourcePath: sourcePath, maxPixel: maxPixel) {
            imageMemCache.setObject(img, forKey: memKey)
            return img
        }

        return nil
    }

    // MARK: - Chat last/preview application

    private func applyChatLastMessageUpdate(chatId: Int64, lastMessageId: Int64, preview: String, date: Int) {
        guard var c = chatsById[chatId] else { return }
        c.lastMessageId = lastMessageId
        c.lastMessagePreview = preview
        c.lastMessageDate = date
        chatsById[chatId] = c
    }

    private func keepOptimisticChatPreviewIfNeeded(chatId: Int64) {
        guard let localLast = messagesByChatId[chatId]?.last else { return }
        guard localLast.isOutgoing else { return }

        if case .sent = localLast.sendState {
            return
        }

        guard var c = chatsById[chatId] else { return }

        switch localLast.sendState {
        case .pending:
            c.lastMessagePreview = "You: (sending…) \(localLast.previewText)"
        case .failed:
            c.lastMessagePreview = "You: (failed) \(localLast.previewText)"
        case .sent:
            break
        }

        c.lastMessageDate = localLast.date
        c.lastMessageId = localLast.id
        chatsById[chatId] = c
    }

    private func applyChatReadInboxUpdate(chatId: Int64, lastReadInboxMessageId: Int64, unreadCount: Int32) {
        guard var c = chatsById[chatId] else { return }
        c.lastReadInboxMessageId = lastReadInboxMessageId
        c.unreadCount = unreadCount
        chatsById[chatId] = c
    }

    private func requestUserIfNeeded(_ userId: Int64?) {
        guard let id = userId else { return }
        guard usersById[id] == nil else { return }
        td.send(#"{"@type":"getUser","user_id":\#(id)}"#)
    }

    // MARK: - Optimistic timeline helpers

    private func sortChronological(_ arr: [TGMessage]) -> [TGMessage] {
        arr.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    private func optimisticInsertMessage(_ msg: TGMessage) {
        var arr = messagesByChatId[msg.chatId] ?? []
        arr.append(msg)
        arr = sortChronological(arr)
        if arr.count > 800 { arr.removeFirst(arr.count - 800) }
        messagesByChatId[msg.chatId] = arr

        if var c = chatsById[msg.chatId] {
            c.lastMessageId = msg.id
            c.lastMessageDate = msg.date
            switch msg.sendState {
            case .pending:
                c.lastMessagePreview = "You: (sending…) \(msg.previewText)"
            case .failed:
                c.lastMessagePreview = "You: (failed) \(msg.previewText)"
            case .sent:
                c.lastMessagePreview = msg.previewText
            }
            chatsById[msg.chatId] = c
        }
    }

    private func appendMessage(_ msg: TGMessage, chatId: Int64) {
        var arr = messagesByChatId[chatId] ?? []
        if arr.contains(where: { $0.id == msg.id }) {
            return
        }
        arr.append(msg)
        arr = sortChronological(arr)
        if arr.count > 800 { arr.removeFirst(arr.count - 800) }
        messagesByChatId[chatId] = arr
    }

    private func replaceMessage(chatId: Int64, oldId: Int64, newMessage: TGMessage) {
        var arr = messagesByChatId[chatId] ?? []
        if let idx = arr.firstIndex(where: { $0.id == oldId }) {
            arr[idx] = newMessage
        } else {
            arr.append(newMessage)
        }
        arr = sortChronological(arr)
        if arr.count > 800 { arr.removeFirst(arr.count - 800) }
        messagesByChatId[chatId] = arr
    }

    private func markMessagePending(chatId: Int64, id: Int64) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        var m = arr[idx]
        m.sendState = .pending
        m.canRetry = false
        arr[idx] = m
        messagesByChatId[chatId] = sortChronological(arr)
        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
    }

    private func updateChatLastFromLocalTimeline(chatId: Int64) {
        guard let last = messagesByChatId[chatId]?.last else { return }
        if var c = chatsById[chatId] {
            c.lastMessageId = last.id
            c.lastMessageDate = last.date
            switch last.sendState {
            case .pending:
                c.lastMessagePreview = "You: (sending…) \(last.previewText)"
            case .failed:
                c.lastMessagePreview = "You: (failed) \(last.previewText)"
            case .sent:
                c.lastMessagePreview = last.previewText
            }
            chatsById[chatId] = c
        }
    }

    // MARK: - Reconciliation with TDLib send lifecycle

    private struct FunctionResponseMessage {
        let extra: String?
        let message: TGMessage
        let raw: [String: Any]
    }

    private func parseMessageFunctionResponse(_ upd: String) -> FunctionResponseMessage? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "message" else { return nil }

        let extra = obj["@extra"] as? String
        guard extra != nil else { return nil }

        guard let msg = parseMessageObject(obj) else { return nil }
        return FunctionResponseMessage(extra: extra, message: msg, raw: obj)
    }

    private func handleFunctionResponseMessage(_ resp: FunctionResponseMessage) {
        let msg = resp.message
        if tryReconcileOutgoingPendingMessage(msg) {
            updateChatLastFromLocalTimeline(chatId: msg.chatId)
        }
    }

    private struct SendSucceeded {
        let message: TGMessage
        let oldMessageId: Int64
    }

    private func parseUpdateMessageSendSucceeded(_ upd: String) -> SendSucceeded? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageSendSucceeded" else { return nil }
        guard let oldNum = obj["old_message_id"] as? NSNumber else { return nil }
        guard let msgObj = obj["message"] as? [String: Any] else { return nil }
        guard let msg = parseMessageObject(msgObj) else { return nil }
        return SendSucceeded(message: msg, oldMessageId: oldNum.int64Value)
    }

    private struct SendFailed {
        let message: TGMessage
        let oldMessageId: Int64
        let errorText: String
        let canRetry: Bool
    }

    private func parseUpdateMessageSendFailed(_ upd: String) -> SendFailed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageSendFailed" else { return nil }
        guard let oldNum = obj["old_message_id"] as? NSNumber else { return nil }
        guard let msgObj = obj["message"] as? [String: Any] else { return nil }
        guard var msg = parseMessageObject(msgObj) else { return nil }

        var errText = "Failed to send"
        if let e = obj["error"] as? [String: Any] {
            let em = (e["message"] as? String) ?? ""
            let ec = (e["code"] as? NSNumber)?.intValue
            if !em.isEmpty, let ec {
                errText = "\(em) (\(ec))"
            } else if !em.isEmpty {
                errText = em
            }
        }

        msg.sendState = .failed(errorText: errText)

        var canRetry = msg.canRetry
        if let sending = msgObj["sending_state"] as? [String: Any],
           (sending["@type"] as? String) == "messageSendingStateFailed" {
            canRetry = (sending["can_retry"] as? Bool) ?? canRetry
        }

        msg.canRetry = canRetry
        return SendFailed(message: msg, oldMessageId: oldNum.int64Value, errorText: errText, canRetry: canRetry)
    }

    private func handleSendSucceeded(_ succ: SendSucceeded) {
        let chatId = succ.message.chatId
        var final = succ.message
        final.sendState = .sent
        final.canRetry = false

        replaceMessage(chatId: chatId, oldId: succ.oldMessageId, newMessage: final)

        if let localId = localIdByTempMessageId[succ.oldMessageId] {
            pendingByLocalId.removeValue(forKey: localId)
            localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
            localIdByTempMessageId.removeValue(forKey: succ.oldMessageId)
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    private func handleSendFailed(_ fail: SendFailed) {
        let chatId = fail.message.chatId
        replaceMessage(chatId: chatId, oldId: fail.oldMessageId, newMessage: fail.message)

        if let localId = localIdByTempMessageId[fail.oldMessageId] {
            pendingByLocalId.removeValue(forKey: localId)
            localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
            localIdByTempMessageId.removeValue(forKey: fail.oldMessageId)
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    private func tryReconcileOutgoingPendingMessage(_ msg: TGMessage) -> Bool {
        guard msg.isOutgoing else { return false }
        guard let sid = msg.sendingId else { return false }
        guard let localId = localIdBySendingId[sid] else { return false }
        guard var link = pendingByLocalId[localId] else { return false }

        let chatId = link.chatId
        let placeholderId = link.placeholderId

        var merged = msg
        merged.localId = localId
        merged.sendingId = sid

        replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: merged)

        link.placeholderId = merged.id
        pendingByLocalId[localId] = link
        localIdByTempMessageId[merged.id] = localId

        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        return true
    }

    // MARK: - Edit / content updates

    private struct UpdateMessageEditedParsed {
        let chatId: Int64
        let messageId: Int64
        let editDate: Int
    }

    private func parseUpdateMessageEdited(_ upd: String) -> UpdateMessageEditedParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageEdited" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let messageId = (obj["message_id"] as? NSNumber)?.int64Value else { return nil }
        let editDate = (obj["edit_date"] as? NSNumber)?.intValue ?? 0
        return UpdateMessageEditedParsed(chatId: chatId, messageId: messageId, editDate: editDate)
    }

    private func applyMessageEdited(chatId: Int64, messageId: Int64, editDate: Int) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
        var m = arr[idx]
        m.editedAt = editDate
        arr[idx] = m
        messagesByChatId[chatId] = sortChronological(arr)
    }

    private struct UpdateMessageContentParsed {
        let chatId: Int64
        let messageId: Int64
        let newContent: [String: Any]
    }

    private func parseUpdateMessageContent(_ upd: String) -> UpdateMessageContentParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageContent" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let messageId = (obj["message_id"] as? NSNumber)?.int64Value else { return nil }
        guard let newContent = obj["new_content"] as? [String: Any] else { return nil }
        return UpdateMessageContentParsed(chatId: chatId, messageId: messageId, newContent: newContent)
    }

    private func applyMessageContentChanged(chatId: Int64, messageId: Int64, newContent: [String: Any]) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }

        let newText = renderPreviewTextFromContent(newContent)
        let old = arr[idx]

        let updated = TGMessage(
            id: old.id,
            chatId: old.chatId,
            date: old.date,
            isOutgoing: old.isOutgoing,
            senderUserId: old.senderUserId,
            text: newText,
            sendState: old.sendState,
            localId: old.localId,
            sendingId: old.sendingId,
            editedAt: old.editedAt,
            canRetry: old.canRetry
        )

        arr[idx] = updated
        messagesByChatId[chatId] = sortChronological(arr)
        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    // MARK: - Delete updates

    private struct UpdateDeleteMessagesParsed {
        let chatId: Int64
        let messageIds: [Int64]
    }

    private func parseUpdateDeleteMessages(_ upd: String) -> UpdateDeleteMessagesParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateDeleteMessages" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        let ids = (obj["message_ids"] as? [NSNumber])?.map { $0.int64Value } ?? []
        guard !ids.isEmpty else { return nil }
        return UpdateDeleteMessagesParsed(chatId: chatId, messageIds: ids)
    }

    private func applyMessagesDeleted(chatId: Int64, messageIds: [Int64]) {
        if var arr = messagesByChatId[chatId], !arr.isEmpty {
            let s = Set(messageIds)
            arr.removeAll { s.contains($0.id) }
            messagesByChatId[chatId] = arr
        }

        for id in messageIds {
            if let localId = localIdByTempMessageId[id] {
                pendingByLocalId.removeValue(forKey: localId)
                localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
                localIdByTempMessageId.removeValue(forKey: id)
            }
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    // MARK: - Parsing helpers (content -> preview text)

    private func renderPreviewTextFromContent(_ content: [String: Any]) -> String {
        guard let ctype = content["@type"] as? String else { return "(unsupported)" }
        switch ctype {
        case "messageText":
            if let t = content["text"] as? [String: Any],
               let s = t["text"] as? String { return s }
            return ""
        case "messageSticker":
            if let sticker = content["sticker"] as? [String: Any],
               let emoji = sticker["emoji"] as? String { return emoji }
            return "🧩 Sticker"
        case "messagePhoto": return "🖼 Photo"
        case "messageVideo": return "🎬 Video"
        case "messageVoiceNote": return "🎤 Voice"
        case "messageDocument": return "📎 File"
        default:
            return "(\(ctype))"
        }
    }

    // MARK: - JSON helpers

    private func sendJSON(_ obj: Any) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8)
        else { return }
        td.send(str)
    }

    private func parseJSON(_ upd: String) -> [String: Any]? {
        guard let data = upd.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Parsing (auth/chats/users/messages)

    private func parseAuthState(from upd: String) -> String? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateAuthorizationState" else { return nil }
        guard let auth = obj["authorization_state"] as? [String: Any] else { return nil }
        return auth["@type"] as? String
    }

    private func parseChatsResponse(_ upd: String) -> [Int64]? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "chats" else { return nil }
        guard let ids = obj["chat_ids"] as? [NSNumber] else { return nil }
        return ids.map { $0.int64Value }
    }

    /// Returns (chat, smallFileId, bigFileId, bestExistingPath)
    private func parseChatObject(_ upd: String) -> (TGChat, Int32?, Int32?, String?)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "chat" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let title = (obj["title"] as? String) ?? "(no title)"
        let kind = parseChatKind(obj)
        let order = parseChatOrder(obj)
        let unreadCount = (obj["unread_count"] as? NSNumber)?.int32Value ?? 0
        let lastReadInboxMessageId = (obj["last_read_inbox_message_id"] as? NSNumber)?.int64Value ?? 0

        var preview = ""
        var lastDate = 0
        var lastMessageId: Int64 = 0
        if let last = obj["last_message"] as? [String: Any],
           let msg = parseMessageObject(last) {
            preview = msg.previewText
            lastDate = msg.date
            lastMessageId = msg.id
        }

        var smallId: Int32? = nil
        var bigId: Int32? = nil
        var bestPath: String? = nil

        if let photo = obj["photo"] as? [String: Any] {
            let extracted = extractChatPhotoIdsAndPaths(photo)
            smallId = extracted.smallId
            bigId = extracted.bigId
            // Prefer small for UI; fall back to big.
            bestPath = extracted.smallPath ?? extracted.bigPath
        }

        var chat = TGChat(
            id: id,
            title: title,
            kind: kind,
            order: order,
            lastMessagePreview: preview,
            lastMessageDate: lastDate
        )

        chat.unreadCount = unreadCount
        chat.lastReadInboxMessageId = lastReadInboxMessageId
        chat.lastMessageId = lastMessageId

        return (chat, smallId, bigId, bestPath)
    }

    private func parseChatKind(_ obj: [String: Any]) -> TGChatKind {
        guard let t = obj["type"] as? [String: Any],
              let tt = t["@type"] as? String else { return .unknown }

        switch tt {
        case "chatTypePrivate": return .privateChat
        case "chatTypeBasicGroup": return .basicGroup
        case "chatTypeSupergroup": return .supergroup
        case "chatTypeSecret": return .secret
        default: return .unknown
        }
    }

    private func parseChatOrder(_ obj: [String: Any]) -> Int64 {
        guard let positions = obj["positions"] as? [Any] else { return 0 }
        for p in positions {
            guard let dict = p as? [String: Any] else { continue }
            guard let list = dict["list"] as? [String: Any],
                  (list["@type"] as? String) == "chatListMain" else { continue }
            if let orderStr = dict["order"] as? String, let v = Int64(orderStr) { return v }
        }
        return 0
    }

    private func parseUpdateChatTitle(_ upd: String) -> (Int64, String)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatTitle" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let title = obj["title"] as? String else { return nil }
        return (chatId, title)
    }

    private func parseUpdateChatPosition(_ upd: String) -> (Int64, Int64)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatPosition" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let position = obj["position"] as? [String: Any] else { return nil }
        guard let list = position["list"] as? [String: Any],
              (list["@type"] as? String) == "chatListMain" else { return nil }
        guard let orderStr = position["order"] as? String, let order = Int64(orderStr) else { return nil }
        return (chatId, order)
    }

    private func parseUpdateChatLastMessage(_ upd: String) -> (Int64, Int64, String, Int)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatLastMessage" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let last = obj["last_message"] as? [String: Any] else { return nil }
        guard let msg = parseMessageObject(last) else { return nil }
        return (chatId, msg.id, msg.previewText, msg.date)
    }

    private func parseUserObject(_ upd: String) -> TGUser? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "user" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let first = (obj["first_name"] as? String) ?? ""
        let last = (obj["last_name"] as? String) ?? ""
        let username = (obj["username"] as? String) ?? ""
        return TGUser(id: id, firstName: first, lastName: last, username: username)
    }

    // MARK: - Current user (me) + profile photo (TDLib)

    private func parseMeUserResponse(_ upd: String) -> (TGUser, Int32?, String?)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "user" else { return nil }
        guard (obj["@extra"] as? String) == "getMe" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let first = (obj["first_name"] as? String) ?? ""
        let last = (obj["last_name"] as? String) ?? ""
        let username = (obj["username"] as? String) ?? ""

        let user = TGUser(id: id, firstName: first, lastName: last, username: username)

        var photoFileId: Int32? = nil
        var photoPath: String? = nil

        if let pp = obj["profile_photo"] as? [String: Any] {
            let extracted = extractPhotoFileIdAndPath(pp)
            photoFileId = extracted.fileId
            photoPath = extracted.path
        }

        return (user, photoFileId, photoPath)
    }

    private struct PhotoExtract {
        let fileId: Int32?
        let path: String?
    }

    private func extractPhotoFileIdAndPath(_ photo: [String: Any]) -> PhotoExtract {
        func pick(from entry: [String: Any]) -> (Int32?, String?) {
            let id = (entry["id"] as? NSNumber)?.int32Value
            guard let local = entry["local"] as? [String: Any] else { return (id, nil) }

            let done = (local["is_downloading_completed"] as? Bool) ?? false
            let p = (local["path"] as? String) ?? ""
            guard !p.isEmpty else { return (id, nil) }

            if done || FileManager.default.fileExists(atPath: p) {
                return (id, p)
            }
            return (id, nil)
        }

        var fileId: Int32? = nil
        var path: String? = nil

        if let big = photo["big"] as? [String: Any] {
            let (id, p) = pick(from: big)
            if let id { fileId = id }
            if let p { path = p }
        }

        if fileId == nil || path == nil {
            if let small = photo["small"] as? [String: Any] {
                let (id, p) = pick(from: small)
                if fileId == nil, let id { fileId = id }
                if path == nil, let p { path = p }
            }
        }

        return PhotoExtract(fileId: fileId, path: path)
    }

    private struct ChatPhotoExtract {
        let smallId: Int32?
        let bigId: Int32?
        let smallPath: String?
        let bigPath: String?
    }

    private func extractChatPhotoIdsAndPaths(_ photo: [String: Any]) -> ChatPhotoExtract {
        func pick(from entry: [String: Any]) -> (Int32?, String?) {
            let id = (entry["id"] as? NSNumber)?.int32Value
            guard let local = entry["local"] as? [String: Any] else { return (id, nil) }

            let done = (local["is_downloading_completed"] as? Bool) ?? false
            let p = (local["path"] as? String) ?? ""
            guard !p.isEmpty else { return (id, nil) }

            if done || FileManager.default.fileExists(atPath: p) {
                return (id, p)
            }
            return (id, nil)
        }

        var smallId: Int32? = nil
        var bigId: Int32? = nil
        var smallPath: String? = nil
        var bigPath: String? = nil

        if let small = photo["small"] as? [String: Any] {
            let (id, p) = pick(from: small)
            smallId = id
            smallPath = p
        }

        if let big = photo["big"] as? [String: Any] {
            let (id, p) = pick(from: big)
            bigId = id
            bigPath = p
        }

        return ChatPhotoExtract(smallId: smallId, bigId: bigId, smallPath: smallPath, bigPath: bigPath)
    }

    private func parseUpdateUser(upt upd: String) -> (TGUser, Int32?, String?)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateUser" else { return nil }
        guard let uo = obj["user"] as? [String: Any] else { return nil }

        let id = (uo["id"] as? NSNumber)?.int64Value ?? 0
        let first = (uo["first_name"] as? String) ?? ""
        let last = (uo["last_name"] as? String) ?? ""
        let username = (uo["username"] as? String) ?? ""

        let user = TGUser(id: id, firstName: first, lastName: last, username: username)

        var photoFileId: Int32? = nil
        var photoPath: String? = nil
        if let pp = uo["profile_photo"] as? [String: Any] {
            let extracted = extractPhotoFileIdAndPath(pp)
            photoFileId = extracted.fileId
            photoPath = extracted.path
        }

        return (user, photoFileId, photoPath)
    }

    private func downloadMyPhotoIfNeeded(fileId: Int32) {
        if let p = myProfilePhotoPath,
           !p.isEmpty,
           FileManager.default.fileExists(atPath: p) {
            return
        }

        let req: [String: Any] = [
            "@type": "downloadFile",
            "@extra": "downloadMePhoto",
            "file_id": fileId,
            "priority": 32,
            "offset": 0,
            "limit": 0,
            "synchronous": false
        ]
        sendJSON(req)
    }

    private func parseUpdateFilePathIfMyPhoto(_ upd: String) -> String? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateFile" else { return nil }
        guard let file = obj["file"] as? [String: Any] else { return nil }
        guard let idNum = file["id"] as? NSNumber else { return nil }

        let fid = idNum.int32Value
        guard let target = myPhotoFileId, fid == target else { return nil }

        guard let local = file["local"] as? [String: Any] else { return nil }
        let done = (local["is_downloading_completed"] as? Bool) ?? false
        let path = (local["path"] as? String) ?? ""

        guard !path.isEmpty else { return nil }

        if done { return path }
        if FileManager.default.fileExists(atPath: path) { return path }
        return nil
    }

    private func parseUpdateFilePathIfChatAvatar(_ upd: String) -> (Int64, Int32, String)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateFile" else { return nil }
        guard let file = obj["file"] as? [String: Any] else { return nil }
        guard let idNum = file["id"] as? NSNumber else { return nil }

        let fid = idNum.int32Value
        guard let chatId = chatIdByAvatarFileId[fid] else { return nil }

        guard let local = file["local"] as? [String: Any] else { return nil }
        let done = (local["is_downloading_completed"] as? Bool) ?? false
        let path = (local["path"] as? String) ?? ""

        guard !path.isEmpty else { return nil }

        if FileManager.default.fileExists(atPath: path) {
            return (chatId, fid, path)
        }

        guard done else { return nil }
        return (chatId, fid, path)
    }

    private func parseUpdateChatPhoto(_ upd: String) -> (Int64, Int32?, Int32?, String?)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatPhoto" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }

        guard let photo = obj["photo"] as? [String: Any] else {
            // Removed photo
            chatAvatarPathByChatId.removeValue(forKey: chatId)
            chatAvatarMetaByChatId.removeValue(forKey: chatId)
            return (chatId, nil, nil, nil)
        }

        let extracted = extractChatPhotoIdsAndPaths(photo)
        let best = extracted.smallPath ?? extracted.bigPath
        return (chatId, extracted.smallId, extracted.bigId, best)
    }

    private struct MessagesResponse { let extra: String; let messages: [TGMessage] }

    private func parseMessagesResponse(_ upd: String) -> MessagesResponse? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "messages" else { return nil }
        guard let extra = obj["@extra"] as? String, extra.hasPrefix("history:") else { return nil }

        guard let anyArr = obj["messages"] as? [Any] else {
            return MessagesResponse(extra: extra, messages: [])
        }

        let msgs = anyArr.compactMap { $0 as? [String: Any] }.compactMap(parseMessageObject(_:))
        return MessagesResponse(extra: extra, messages: msgs)
    }

    private func parseUpdateNewMessage(_ upd: String) -> (Int64, TGMessage)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateNewMessage" else { return nil }
        guard let msgObj = obj["message"] as? [String: Any] else { return nil }
        guard let chatId = (msgObj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let msg = parseMessageObject(msgObj) else { return nil }
        return (chatId, msg)
    }

    private func parseMessageObject(_ obj: [String: Any]) -> TGMessage? {
        guard (obj["@type"] as? String) == "message" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let chatId = (obj["chat_id"] as? NSNumber)?.int64Value ?? 0
        let date = (obj["date"] as? NSNumber)?.intValue ?? 0
        let editDate = (obj["edit_date"] as? NSNumber)?.intValue ?? 0
        let isOutgoing = (obj["is_outgoing"] as? Bool) ?? false

        var senderUserId: Int64? = nil
        if let sender = obj["sender_id"] as? [String: Any],
           (sender["@type"] as? String) == "messageSenderUser",
           let uid = sender["user_id"] as? NSNumber {
            senderUserId = uid.int64Value
        }

        var text = "(unsupported)"
        if let content = obj["content"] as? [String: Any] {
            text = renderPreviewTextFromContent(content)
        }

        var sendState: TGMessageSendState = .sent
        var sendingId: Int32? = nil
        var canRetry: Bool = false

        if let sending = obj["sending_state"] as? [String: Any],
           let st = sending["@type"] as? String {
            switch st {
            case "messageSendingStatePending":
                sendState = .pending
                if let sidNum = sending["sending_id"] as? NSNumber {
                    sendingId = sidNum.int32Value
                }
            case "messageSendingStateFailed":
                canRetry = (sending["can_retry"] as? Bool) ?? false
                if let err = sending["error"] as? [String: Any],
                   let em = err["message"] as? String,
                   !em.isEmpty {
                    sendState = .failed(errorText: em)
                } else {
                    sendState = .failed(errorText: "Failed to send")
                }
            default:
                break
            }
        }

        var m = TGMessage(
            id: id,
            chatId: chatId,
            date: date,
            isOutgoing: isOutgoing,
            senderUserId: senderUserId,
            text: text,
            sendState: sendState,
            localId: nil,
            sendingId: sendingId,
            editedAt: (editDate > 0 ? editDate : nil),
            canRetry: canRetry
        )

        if editDate > 0 {
            m.editedAt = editDate
        }

        return m
    }

    // MARK: - Chat read inbox update parser

    private func parseUpdateChatReadInbox(_ upd: String) -> (Int64, Int64, Int32)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatReadInbox" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }

        let lastRead = (obj["last_read_inbox_message_id"] as? NSNumber)?.int64Value ?? 0
        let unread = (obj["unread_count"] as? NSNumber)?.int32Value ?? 0
        return (chatId, lastRead, unread)
    }

    // MARK: - Logging

    private func pushLog(_ s: String) {
        logs.append(s)
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }
}
// MARK: - Stable thumb id fallback (avoid fileId == 0 collisions)

private func fnv1a32(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 {
        h ^= UInt32(b)
        h &*= 16777619
    }
    return h
}

private func stableThumbFallbackFileId(sourcePath: String, kind: String, maxPixel: Int) -> Int32 {
    // Make a stable, non-zero, positive Int32.
    let key = "\(kind)|\(maxPixel)|\(sourcePath)"
    let h = fnv1a32(key)
    let nonZeroPositive = (h & 0x7fffffff) | 1
    return Int32(nonZeroPositive)
}
