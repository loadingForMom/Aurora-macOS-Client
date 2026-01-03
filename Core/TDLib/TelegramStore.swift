//
//  TelegramStore.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import Combine

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

    private var didLoadInitialData = false
    private var didSendTdlibParameters = false

    private struct HistoryJob {
        let chatId: Int64
        let targetCount: Int
        var nextFromMessageId: Int64
        var accById: [Int64: TGMessage]
    }
    private var historyJobs: [String: HistoryJob] = [:]

    init() {
        td.startReceiveLoop { [weak self] upd in
            Task { @MainActor in
                self?.pushLog(upd)
                self?.handleUpdate(upd)
            }
        }

        td.send(#"{"@type":"getOption","name":"version"}"#)
    }

    var sortedChats: [TGChat] {
        chatsById.values.sorted {
            if $0.order != $1.order { return $0.order > $1.order }
            if $0.lastMessageDate != $1.lastMessageDate { return $0.lastMessageDate > $1.lastMessageDate }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func userDisplayName(_ userId: Int64?) -> String {
        guard let id = userId else { return "" }
        return usersById[id]?.displayName ?? "User \(id)"
    }

    func selectChat(_ chatId: Int64) {
        selectedChatId = chatId
        loadLatestHistory(chatId: chatId)
    }

    func sendText(chatId: Int64, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let req: [String: Any] = [
            "@type": "sendMessage",
            "chat_id": chatId,
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
        isLoadingHistory = true
        let extra = "history:\(chatId):\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(chatId: chatId, targetCount: 160, nextFromMessageId: 0, accById: [:])
        sendChatHistory(chatId: chatId, fromMessageId: 0, limit: 100, extra: extra)
    }

    private func sendChatHistory(chatId: Int64, fromMessageId: Int64, limit: Int, extra: String) {
        let req: [String: Any] = [
            "@type": "getChatHistory",
            "@extra": extra,
            "chat_id": chatId,
            "from_message_id": fromMessageId,
            "offset": 0,
            "limit": limit,
            "only_local": false
        ]
        sendJSON(req)
    }

    // MARK: - Update processing

    private func handleUpdate(_ upd: String) {
        if let st = parseAuthState(from: upd) {
            authState = st
        }

        if authState == "authorizationStateWaitTdlibParameters", !didSendTdlibParameters {
            if sendTdlibParametersIfPossible() {
                didSendTdlibParameters = true
            }
        }

        if authState == "authorizationStateReady", !didLoadInitialData {
            didLoadInitialData = true
            td.send(#"{"@type":"getMe"}"#)
            td.send(#"{"@type":"getChats","limit":200}"#)
        }

        if let ids = parseChatsResponse(upd) {
            for id in ids {
                td.send(#"{"@type":"getChat","chat_id":\#(id)}"#)
            }
        }

        if let chat = parseChatObject(upd) {
            chatsById[chat.id] = chat
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

        if let (chatId, preview, date) = parseUpdateChatLastMessage(upd) {
            if var c = chatsById[chatId] {
                c.lastMessagePreview = preview
                c.lastMessageDate = date
                chatsById[chatId] = c
            }
        }

        if let user = parseUserObject(upd) {
            usersById[user.id] = user
        }

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
                let ordered = job.accById.values.sorted { $0.date < $1.date }
                messagesByChatId[job.chatId] = Array(ordered.suffix(job.targetCount))
                historyJobs.removeValue(forKey: res.extra)
                if selectedChatId == job.chatId { isLoadingHistory = false }
            } else {
                historyJobs[res.extra] = job
                sendChatHistory(chatId: job.chatId,
                                fromMessageId: job.nextFromMessageId,
                                limit: min(remaining, 100),
                                extra: res.extra)
            }
        }

        if let (chatId, msg) = parseUpdateNewMessage(upd) {
            requestUserIfNeeded(msg.senderUserId)
            var arr = messagesByChatId[chatId] ?? []
            arr.append(msg)
            if arr.count > 800 { arr.removeFirst(arr.count - 800) }
            messagesByChatId[chatId] = arr

            if var c = chatsById[chatId] {
                c.lastMessagePreview = msg.previewText
                c.lastMessageDate = msg.date
                chatsById[chatId] = c
            }
        }
    }

    private func requestUserIfNeeded(_ userId: Int64?) {
        guard let id = userId else { return }
        guard usersById[id] == nil else { return }
        td.send(#"{"@type":"getUser","user_id":\#(id)}"#)
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

    // MARK: - Parsing

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

    private func parseChatObject(_ upd: String) -> TGChat? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "chat" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let title = (obj["title"] as? String) ?? "(no title)"
        let kind = parseChatKind(obj)
        let order = parseChatOrder(obj)

        var preview = ""
        var lastDate = 0
        if let last = obj["last_message"] as? [String: Any],
           let msg = parseMessageObject(last) {
            preview = msg.previewText
            lastDate = msg.date
        }

        return TGChat(id: id, title: title, kind: kind, order: order, lastMessagePreview: preview, lastMessageDate: lastDate)
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

    private func parseUpdateChatLastMessage(_ upd: String) -> (Int64, String, Int)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatLastMessage" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let last = obj["last_message"] as? [String: Any] else { return nil }
        guard let msg = parseMessageObject(last) else { return nil }
        return (chatId, msg.previewText, msg.date)
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
        let isOutgoing = (obj["is_outgoing"] as? Bool) ?? false

        var senderUserId: Int64? = nil
        if let sender = obj["sender_id"] as? [String: Any],
           (sender["@type"] as? String) == "messageSenderUser",
           let uid = sender["user_id"] as? NSNumber {
            senderUserId = uid.int64Value
        }

        var text = "(unsupported)"
        if let content = obj["content"] as? [String: Any],
           let ctype = content["@type"] as? String {
            switch ctype {
            case "messageText":
                if let t = content["text"] as? [String: Any],
                   let s = t["text"] as? String { text = s } else { text = "" }
            case "messageSticker":
                if let sticker = content["sticker"] as? [String: Any],
                   let emoji = sticker["emoji"] as? String { text = emoji } else { text = "🧩 Sticker" }
            case "messagePhoto": text = "🖼 Photo"
            case "messageVideo": text = "🎬 Video"
            case "messageVoiceNote": text = "🎤 Voice"
            case "messageDocument": text = "📎 File"
            default: text = "(\(ctype))"
            }
        }

        return TGMessage(id: id, chatId: chatId, date: date, isOutgoing: isOutgoing, senderUserId: senderUserId, text: text)
    }

    // MARK: - Logging

    private func pushLog(_ s: String) {
        logs.append(s)
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }
}
