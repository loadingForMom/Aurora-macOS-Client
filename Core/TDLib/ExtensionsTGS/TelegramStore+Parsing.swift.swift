//  TelegramStore+Parsing.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    // MARK: - JSON helpers

    func sendJSON(_ obj: Any) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8)
        else { return }
        td.send(str)
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
        for p in positions {
            guard let dict = p as? [String: Any] else { continue }
            guard let list = dict["list"] as? [String: Any],
                  (list["@type"] as? String) == "chatListMain" else { continue }
            if let orderStr = dict["order"] as? String, let v = Int64(orderStr) { return v }
        }
        return 0
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

    func parseUpdateChatLastMessage(_ upd: String) -> (Int64, TGMessage)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatLastMessage" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let last = obj["last_message"] as? [String: Any] else { return nil }
        guard let msg = parseMessageObject(last, expectedChatId: chatId) else { return nil }
        return (chatId, msg)
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
        sendJSON(req)
    }

    func parseUpdateFilePathIfMyPhoto(_ upd: String) -> String? {
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

    func parseUpdateFilePathIfChatAvatar(_ upd: String) -> (Int64, Int32, String)? {
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

    func parseUpdateChatPhoto(_ upd: String) -> (Int64, Int32?, Int32?, String?)? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateChatPhoto" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }

        guard let photo = obj["photo"] as? [String: Any] else {
            chatAvatarPathByChatId.removeValue(forKey: chatId)
            chatAvatarMetaByChatId.removeValue(forKey: chatId)
            return (chatId, nil, nil, nil)
        }

        let extracted = extractChatPhotoIdsAndPaths(photo)
        let best = extracted.smallPath ?? extracted.bigPath
        return (chatId, extracted.smallId, extracted.bigId, best)
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

#if DEBUG
        if let expectedChatId {
            assert(m.chatId == expectedChatId, "TDLib message chatId mismatch: expected \(expectedChatId) got \(m.chatId)")
        }
#endif

        return m
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
