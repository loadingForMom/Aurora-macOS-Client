//  TelegramStore+Parsing.swift
//  Aurora
//

import Foundation
import os

extension TelegramStore {

    // MARK: - JSON helpers

    func sendJSON(_ obj: Any, priority: TDLibClient.SendPriority = .high) {
        guard JSONSerialization.isValidJSONObject(obj) else {
            log.error("tdlib invalid json: \(String(describing: obj), privacy: .public)")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: obj)
            if let str = String(data: data, encoding: .utf8) {
                log.debug("tdlib send \(str, privacy: .public)")
                td.send(str, priority: priority)
            } else {
                log.error("tdlib encode error: invalid utf8")
            }
        } catch {
            log.error("tdlib encode error: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    func sendIfAuthorized(
        _ obj: Any,
        typeOverride: String? = nil,
        priority: TDLibClient.SendPriority = .high
    ) -> Bool {
        let type = typeOverride
            ?? (obj as? [String: Any])?["@type"] as? String
            ?? "unknown"
        guard isRequestAuthorizedSnapshot() else {
            log.info("Blocked TDLib request (not authorized yet): \(type, privacy: .public)")
            return false
        }
        sendJSON(obj, priority: priority)
        return true
    }

    func parseTdError(_ resp: String) -> (code: Int, message: String, extra: String?)? {
        guard let obj = parseJSON(resp) else { return nil }
        guard (obj["@type"] as? String) == "error" else { return nil }
        let code = (obj["code"] as? NSNumber)?.intValue ?? -1
        let message = obj["message"] as? String ?? "(unknown)"
        let extra = obj["@extra"] as? String
        return (code, message, extra)
    }

    func parseJSON(_ upd: String) -> [String: Any]? {
        if upd == lastParsedUpdate {
            return lastParsedObject
        }

        guard let data = upd.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        lastParsedUpdate = upd
        lastParsedObject = obj
        return obj
    }

    // MARK: - Auth

    func parseAuthState(from upd: String) -> String? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateAuthorizationState" else { return nil }
        guard let auth = obj["authorization_state"] as? [String: Any] else { return nil }
        return auth["@type"] as? String
    }

    // MARK: - Chats list / chat object

    func parseChatsResponse(_ upd: String) -> [Int64]? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "chats" else { return nil }
        guard let ids = obj["chat_ids"] as? [NSNumber] else { return nil }
        return ids.map { $0.int64Value }
    }

    struct BlockedMessageSendersResponse {
        let extra: String
        let totalCount: Int
        let senders: [BlockedSenderRef]
    }

    func parseBlockedMessageSendersResponse(_ upd: String) -> BlockedMessageSendersResponse? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "messageSenders" else { return nil }
        guard let extra = obj["@extra"] as? String else { return nil }
        guard extra.hasPrefix("blockedSenders:main:") else { return nil }

        let totalCount = (obj["total_count"] as? NSNumber)?.intValue ?? 0
        let rawSenders = obj["senders"] as? [Any] ?? []
        let senders = rawSenders.compactMap(parseBlockedSenderRef)

        return BlockedMessageSendersResponse(
            extra: extra,
            totalCount: totalCount,
            senders: senders
        )
    }

    private func parseBlockedSenderRef(_ raw: Any) -> BlockedSenderRef? {
        guard let sender = raw as? [String: Any] else { return nil }
        guard let type = sender["@type"] as? String else { return nil }

        switch type {
        case "messageSenderUser":
            guard let userId = (sender["user_id"] as? NSNumber)?.int64Value else { return nil }
            return .user(userId)
        case "messageSenderChat":
            guard let chatId = (sender["chat_id"] as? NSNumber)?.int64Value else { return nil }
            return .chat(chatId)
        default:
            return nil
        }
    }

    /// Returns (chat, lastMessage, smallFileId, bigFileId, bestExistingPath)
    func parseChatObject(_ upd: String) -> (TGChat, TGMessage?, Int32?, Int32?, String?)? {
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
        var lastMessage: TGMessage? = nil
        if let last = obj["last_message"] as? [String: Any],
           let msg = parseMessageObject(last, expectedChatId: id) {
            preview = msg.previewText
            lastDate = msg.date
            lastMessageId = msg.id
            lastMessage = msg
        }

        var smallId: Int32? = nil
        var bigId: Int32? = nil
        var bestPath: String? = nil

        if let photo = obj["photo"] as? [String: Any] {
            let extracted = extractChatPhotoIdsAndPaths(photo)
            smallId = extracted.smallId
            bigId = extracted.bigId
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

        return (chat, lastMessage, smallId, bigId, bestPath)
    }

    func parseChatKind(_ obj: [String: Any]) -> TGChatKind {
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

    func parseChatOrder(_ obj: [String: Any]) -> Int64 {
        guard let positions = obj["positions"] as? [Any] else { return 0 }
        return parseMainChatOrder(fromPositions: positions) ?? 0
    }

    func parseMainChatOrder(fromPositions positions: [Any]) -> Int64? {
        for p in positions {
            guard let dict = p as? [String: Any] else { continue }
            guard let list = dict["list"] as? [String: Any],
                  (list["@type"] as? String) == "chatListMain" else { continue }
            if let orderStr = dict["order"] as? String, let v = Int64(orderStr) { return v }
        }
        return nil
    }

    func parseUpdateChatTitle(_ upd: String) -> (Int64, String)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatTitle" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let title = obj["title"] as? String else { return nil }
        return (chatId, title)
    }

    func parseUpdateChatPosition(_ upd: String) -> (Int64, Int64)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatPosition" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let position = obj["position"] as? [String: Any] else { return nil }
        guard let list = position["list"] as? [String: Any],
              (list["@type"] as? String) == "chatListMain" else { return nil }
        guard let orderStr = position["order"] as? String, let order = Int64(orderStr) else { return nil }
        return (chatId, order)
    }

    struct UpdateChatLastMessageParsed {
        let chatId: Int64
        let lastMessage: TGMessage?
        let order: Int64?
    }

    func parseUpdateChatLastMessage(_ upd: String) -> UpdateChatLastMessageParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatLastMessage" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        let positions = obj["positions"] as? [Any] ?? []
        let order = parseMainChatOrder(fromPositions: positions)

        let lastMessage: TGMessage?
        if let last = obj["last_message"] as? [String: Any] {
            lastMessage = parseMessageObject(last, expectedChatId: chatId)
        } else {
            lastMessage = nil
        }

        return UpdateChatLastMessageParsed(chatId: chatId, lastMessage: lastMessage, order: order)
    }

    // MARK: - User objects

    func parseUserObject(_ upd: String) -> TGUser? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "user" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let first = (obj["first_name"] as? String) ?? ""
        let last = (obj["last_name"] as? String) ?? ""
        let username = (obj["username"] as? String) ?? ""
        return TGUser(id: id, firstName: first, lastName: last, username: username)
    }

    // MARK: - Me

    func parseMeUserResponse(_ upd: String) -> (TGUser, Int32?, String?)? {
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

    struct PhotoExtract {
        let fileId: Int32?
        let path: String?
    }

    func extractPhotoFileIdAndPath(_ photo: [String: Any]) -> PhotoExtract {
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

    struct ChatPhotoExtract {
        let smallId: Int32?
        let bigId: Int32?
        let smallPath: String?
        let bigPath: String?
    }

    func extractChatPhotoIdsAndPaths(_ photo: [String: Any]) -> ChatPhotoExtract {
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

    func parseUpdateUser(upt upd: String) -> (TGUser, Int32?, String?)? {
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

    @MainActor
    func downloadMyPhotoIfNeeded(fileId: Int32) {
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
        _ = sendIfAuthorized(req)
    }

    func parseUpdateFilePathIfMyPhoto(_ upd: String) -> (Int32, String)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateFile" else { return nil }
        guard let file = obj["file"] as? [String: Any] else { return nil }
        guard let idNum = file["id"] as? NSNumber else { return nil }

        let fid = idNum.int32Value
        guard let local = file["local"] as? [String: Any] else { return nil }
        let done = (local["is_downloading_completed"] as? Bool) ?? false
        let path = (local["path"] as? String) ?? ""

        guard !path.isEmpty else { return nil }

        if done { return (fid, path) }
        if FileManager.default.fileExists(atPath: path) { return (fid, path) }
        return nil
    }

    func parseUpdateFilePathIfChatAvatar(_ upd: String) -> (Int32, String)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateFile" else { return nil }
        guard let file = obj["file"] as? [String: Any] else { return nil }
        guard let idNum = file["id"] as? NSNumber else { return nil }

        let fid = idNum.int32Value
        guard let local = file["local"] as? [String: Any] else { return nil }
        let done = (local["is_downloading_completed"] as? Bool) ?? false
        let path = (local["path"] as? String) ?? ""

        guard !path.isEmpty else { return nil }

        if FileManager.default.fileExists(atPath: path) { return (fid, path) }

        guard done else { return nil }
        return (fid, path)
    }

    struct ChatPhotoUpdate {
        let chatId: Int64
        let smallId: Int32?
        let bigId: Int32?
        let bestPath: String?
        let hasPhoto: Bool
    }

    func parseUpdateChatPhoto(_ upd: String) -> ChatPhotoUpdate? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatPhoto" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }

        guard let photo = obj["photo"] as? [String: Any] else {
            return ChatPhotoUpdate(chatId: chatId, smallId: nil, bigId: nil, bestPath: nil, hasPhoto: false)
        }

        let extracted = extractChatPhotoIdsAndPaths(photo)
        let best = extracted.smallPath ?? extracted.bigPath
        return ChatPhotoUpdate(chatId: chatId, smallId: extracted.smallId, bigId: extracted.bigId, bestPath: best, hasPhoto: true)
    }

    // MARK: - Messages / history

    struct MessagesResponse { let extra: String; let messages: [TGMessage] }

    func parseMessagesResponse(_ upd: String) -> MessagesResponse? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "messages" else { return nil }
        guard let extra = obj["@extra"] as? String, extra.hasPrefix("history:") else { return nil }

        guard let anyArr = obj["messages"] as? [Any] else {
            return MessagesResponse(extra: extra, messages: [])
        }

        let msgs = anyArr
            .compactMap { $0 as? [String: Any] }
            .compactMap { parseMessageObject($0) }
            .sorted { $0.id > $1.id }
        return MessagesResponse(extra: extra, messages: msgs)
    }

    func parseUpdateNewMessage(_ upd: String) -> (Int64, TGMessage)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateNewMessage" else { return nil }
        guard let msgObj = obj["message"] as? [String: Any] else { return nil }
        guard let chatId = (msgObj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let msg = parseMessageObject(msgObj, expectedChatId: chatId) else { return nil }
        return (chatId, msg)
    }

    func parseMessageObject(_ obj: [String: Any], expectedChatId: Int64? = nil) -> TGMessage? {
        guard (obj["@type"] as? String) == "message" else { return nil }

        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let chatId = (obj["chat_id"] as? NSNumber)?.int64Value ?? 0
        let date = (obj["date"] as? NSNumber)?.intValue ?? 0
        let editDate = (obj["edit_date"] as? NSNumber)?.intValue ?? 0
        let isOutgoing = (obj["is_outgoing"] as? Bool) ?? false
        var replyToMessageId: Int64? = nil

        var senderUserId: Int64? = nil
        if let sender = obj["sender_id"] as? [String: Any],
           (sender["@type"] as? String) == "messageSenderUser",
           let uid = sender["user_id"] as? NSNumber {
            senderUserId = uid.int64Value
        }

        var text = "(unsupported)"
        var contentType = "unknown"
        var rawText: String? = nil
        var entities: [TGTextEntity] = []
        if let content = obj["content"] as? [String: Any] {
            text = renderPreviewTextFromContent(content)
            let parsed = parseMessageTextPayload(content)
            contentType = parsed.contentType
            rawText = parsed.rawText
            entities = parsed.entities
        }

        var sendState: TGMessageSendState = .sent
        var sendingId: Int32? = nil
        var canRetry: Bool = false

        if let sending = obj["sending_state"] as? [String: Any],
           let st = sending["@type"] as? String {
            switch st {
            case "messageSendingStatePending":
                sendState = .sending
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
            if let sidNum = sending["sending_id"] as? NSNumber {
                sendingId = sidNum.int32Value
            }
        }
        if sendingId == nil, let sidNum = obj["sending_id"] as? NSNumber {
            sendingId = sidNum.int32Value
        }

        if let replyTo = obj["reply_to"] as? [String: Any] {
            if let messageId = (replyTo["message_id"] as? NSNumber)?.int64Value {
                replyToMessageId = messageId
            } else if let replyToMessageIdNum = (replyTo["reply_to_message_id"] as? NSNumber)?.int64Value {
                replyToMessageId = replyToMessageIdNum
            }
        }
        if replyToMessageId == nil, let replyToMessageIdNum = (obj["reply_to_message_id"] as? NSNumber)?.int64Value {
            replyToMessageId = replyToMessageIdNum
        }

        var m = TGMessage(
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
            localId: nil,
            sendingId: sendingId,
            editedAt: (editDate > 0 ? editDate : nil),
            canRetry: canRetry,
            retryCount: 0,
            nextRetryAt: nil
        )

        if editDate > 0 {
            m.editedAt = editDate
        }

#if DEBUG
        if let expectedChatId {
            assert(m.chatId == expectedChatId, "TDLib message chatId mismatch: expected \(expectedChatId) got \(m.chatId)")
        }
#endif

        return m
    }

    func parseMessageTextPayload(_ content: [String: Any]) -> (contentType: String, rawText: String?, entities: [TGTextEntity]) {
        guard let ctype = content["@type"] as? String else {
            return ("unknown", nil, [])
        }
        guard ctype == "messageText" else {
            return (ctype, nil, [])
        }
        guard let textObj = content["text"] as? [String: Any] else {
            return (ctype, nil, [])
        }
        let rawText = textObj["text"] as? String
        let entities = parseTextEntities(textObj)
        return (ctype, rawText, entities)
    }

    func parseTextEntities(_ textObj: [String: Any]) -> [TGTextEntity] {
        guard let entities = textObj["entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { entity in
            guard let offset = (entity["offset"] as? NSNumber)?.intValue,
                  let length = (entity["length"] as? NSNumber)?.intValue
            else { return nil }

            let typeObj = entity["type"] as? [String: Any]
            let typeName = typeObj?["@type"] as? String ?? ""

            let type: TGTextEntityType
            switch typeName {
            case "textEntityTypeBold":
                type = .bold
            case "textEntityTypeItalic":
                type = .italic
            case "textEntityTypeUnderline":
                type = .underline
            case "textEntityTypeStrikethrough":
                type = .strikethrough
            case "textEntityTypeCode":
                type = .code
            case "textEntityTypePre":
                type = .pre
            case "textEntityTypePreCode":
                type = .preCode(language: typeObj?["language"] as? String)
            case "textEntityTypeTextUrl":
                type = .textUrl(url: typeObj?["url"] as? String ?? "")
            default:
                type = .unknown(typeName)
            }

            return TGTextEntity(type: type, offset: offset, length: length)
        }
    }

    // MARK: - Read inbox

    func parseUpdateChatReadInbox(_ upd: String) -> (Int64, Int64, Int32)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatReadInbox" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }

        let lastRead = (obj["last_read_inbox_message_id"] as? NSNumber)?.int64Value ?? 0
        let unread = (obj["unread_count"] as? NSNumber)?.int32Value ?? 0
        return (chatId, lastRead, unread)
    }
}
