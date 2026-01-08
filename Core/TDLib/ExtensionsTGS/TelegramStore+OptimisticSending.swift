//  TelegramStore+OptimisticSending.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func makeLocalTempId() -> Int64 {
        nextLocalTempId -= 1
        return nextLocalTempId
    }

    func makeSendingId() -> Int32 {
        var x: Int32 = Int32.random(in: 1...Int32.max)
        while localIdBySendingId[x] != nil {
            x = Int32.random(in: 1...Int32.max)
        }
        return x
    }

    // Public wrappers are in TelegramStore.swift
    func _sendText_impl(chatId: Int64, text: String) {
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
            contentType: "messageText",
            rawText: clean,
            entities: [],
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

    func _retrySend_impl(message: TGMessage) {
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

        _sendText_impl(chatId: message.chatId, text: message.text)
    }

    func _deleteMessages_impl(chatId: Int64, messageIds: [Int64], revoke: Bool) {
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

    func _editMessageText_impl(chatId: Int64, messageId: Int64, newText: String) {
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

    func optimisticInsertMessage(_ msg: TGMessage) {
        var arr = messagesByChatId[msg.chatId] ?? []
        arr.append(msg)
        arr = sortChronological(arr)
        if arr.count > 800 { arr.removeFirst(arr.count - 800) }
        messagesByChatId[msg.chatId] = arr
        persistMessage(msg)

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
            persistChat(c)
            persistChatLastMessage(chatId: msg.chatId, messageId: msg.id, preview: c.lastMessagePreview, date: msg.date)
        }
    }

    func markMessagePending(chatId: Int64, id: Int64) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        var m = arr[idx]
        m.sendState = .pending
        m.canRetry = false
        arr[idx] = m
        messagesByChatId[chatId] = sortChronological(arr)
        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        persistMessage(m)
    }

    // MARK: - Reconciliation with TDLib

    struct FunctionResponseMessage {
        let extra: String?
        let message: TGMessage
        let raw: [String: Any]
    }

    func parseMessageFunctionResponse(_ upd: String) -> FunctionResponseMessage? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "message" else { return nil }

        let extra = obj["@extra"] as? String
        guard extra != nil else { return nil }

        let expectedChatId = (obj["chat_id"] as? NSNumber)?.int64Value
        guard let msg = parseMessageObject(obj, expectedChatId: expectedChatId) else { return nil }
        return FunctionResponseMessage(extra: extra, message: msg, raw: obj)
    }

    func handleFunctionResponseMessage(_ resp: FunctionResponseMessage) {
        let msg = resp.message
        if tryReconcileOutgoingPendingMessage(msg) {
            updateChatLastFromLocalTimeline(chatId: msg.chatId)
        }
    }

    struct SendSucceeded {
        let message: TGMessage
        let oldMessageId: Int64
    }

    func parseUpdateMessageSendSucceeded(_ upd: String) -> SendSucceeded? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageSendSucceeded" else { return nil }
        guard let oldNum = obj["old_message_id"] as? NSNumber else { return nil }
        guard let msgObj = obj["message"] as? [String: Any] else { return nil }
        let expectedChatId = (msgObj["chat_id"] as? NSNumber)?.int64Value
        guard let msg = parseMessageObject(msgObj, expectedChatId: expectedChatId) else { return nil }
        return SendSucceeded(message: msg, oldMessageId: oldNum.int64Value)
    }

    struct SendFailed {
        let message: TGMessage
        let oldMessageId: Int64
        let errorText: String
        let canRetry: Bool
    }

    func parseUpdateMessageSendFailed(_ upd: String) -> SendFailed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageSendFailed" else { return nil }
        guard let oldNum = obj["old_message_id"] as? NSNumber else { return nil }
        guard let msgObj = obj["message"] as? [String: Any] else { return nil }
        let expectedChatId = (msgObj["chat_id"] as? NSNumber)?.int64Value
        guard var msg = parseMessageObject(msgObj, expectedChatId: expectedChatId) else { return nil }

        var errText = "Failed to send"
        if let e = obj["error"] as? [String: Any] {
            let em = (e["message"] as? String) ?? ""
            let ec = (e["code"] as? NSNumber)?.intValue
            if !em.isEmpty, let ec { errText = "\(em) (\(ec))" }
            else if !em.isEmpty { errText = em }
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

    func handleSendSucceeded(_ succ: SendSucceeded) {
        let chatId = succ.message.chatId
        var final = succ.message
        final.sendState = .sent
        final.canRetry = false

        replaceMessage(chatId: chatId, oldId: succ.oldMessageId, newMessage: final)

        if let localId = localIdByTempMessageId[succ.oldMessageId] {
            pendingByLocalId.removeValue(forKey: localId)
            localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
            localIdByTempMessageId.removeValue(forKey: succ.oldMessageId)
            serverMessageIdByLocalId[localId] = final.id
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func handleSendFailed(_ fail: SendFailed) {
        let chatId = fail.message.chatId
        replaceMessage(chatId: chatId, oldId: fail.oldMessageId, newMessage: fail.message)

        if let localId = localIdByTempMessageId[fail.oldMessageId] {
            pendingByLocalId.removeValue(forKey: localId)
            localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
            localIdByTempMessageId.removeValue(forKey: fail.oldMessageId)
            serverMessageIdByLocalId.removeValue(forKey: localId)
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func tryReconcileOutgoingPendingMessage(_ msg: TGMessage) -> Bool {
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
        serverMessageIdByLocalId[localId] = merged.id

        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        return true
    }
}
