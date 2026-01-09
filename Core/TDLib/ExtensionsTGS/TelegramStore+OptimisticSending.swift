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
        if let idx = arr.firstIndex(where: { $0.id == msg.id }) {
            arr[idx] = msg
#if DEBUG
            print("[Message][dedupe] chatId=\(msg.chatId) replaced existing id=\(msg.id) (optimisticInsert)")
#endif
        } else {
            arr.append(msg)
        }
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

    func reconcileFunctionResponseSend(extra: String?, msg: TGMessage) -> Bool {
        guard let extra, extra.hasPrefix("send:") else { return false }
        let suffix = String(extra.dropFirst("send:".count))
        guard let localId = UUID(uuidString: suffix),
              var link = pendingByLocalId[localId] else { return false }

        let chatId = link.chatId
        let placeholderId = link.placeholderId

        var merged = msg
        merged.localId = localId
        merged.sendingId = merged.sendingId ?? link.sendingId

        replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: merged)

        link.placeholderId = merged.id
        pendingByLocalId[localId] = link
        localIdByTempMessageId[merged.id] = localId
        serverMessageIdByLocalId[localId] = merged.id

        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        coalesceOutgoingDuplicates(chatId: chatId, localId: localId, keepMessageId: merged.id, fallbackMessage: merged)
        return true
    }

    func handleFunctionResponseMessage(_ resp: FunctionResponseMessage) {
        let msg = resp.message
        let reconciled = reconcileFunctionResponseSend(extra: resp.extra, msg: msg)
            || tryReconcileOutgoingPendingMessage(msg)
#if DEBUG
        if let extra = resp.extra, extra.hasPrefix("send:") {
            print("[SendResponse] handled message response extra=\(extra) reconciled=\(reconciled), skipped timeline insert")
        }
#endif
        if reconciled {
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
        var resolvedLocalId: UUID? = localIdByTempMessageId[succ.oldMessageId]
        var didReplace = replaceMessageIfExists(chatId: chatId, id: succ.oldMessageId, newMessage: final)
        if !didReplace, let sendingId = final.sendingId, let localId = localIdBySendingId[sendingId],
           let link = pendingByLocalId[localId] {
            resolvedLocalId = localId
            didReplace = replaceMessageIfExists(chatId: chatId, id: link.placeholderId, newMessage: final)
            if didReplace {
#if DEBUG
                print("[Reconcile] sendSucceeded matched sending_id=\(sendingId) placeholderId=\(link.placeholderId)")
#endif
            }
        }
        if !didReplace, let localId = resolvedLocalId, let link = pendingByLocalId[localId] {
            didReplace = replaceMessageIfExists(chatId: chatId, id: link.placeholderId, newMessage: final)
        }
        if !didReplace {
            _ = replaceMessageIfExists(chatId: chatId, id: final.id, newMessage: final)
        }

        if resolvedLocalId == nil,
           let localId = serverMessageIdByLocalId.first(where: { $0.value == final.id })?.key {
            resolvedLocalId = localId
        }

        coalesceOutgoingDuplicates(chatId: chatId, localId: resolvedLocalId, keepMessageId: final.id, fallbackMessage: final)
        if succ.oldMessageId != final.id {
            _ = removeMessageById(chatId: chatId, id: succ.oldMessageId)
        }

        if let localId = resolvedLocalId {
            pendingByLocalId.removeValue(forKey: localId)
            localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
            localIdByTempMessageId.removeValue(forKey: succ.oldMessageId)
            serverMessageIdByLocalId[localId] = final.id
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func handleSendFailed(_ fail: SendFailed) {
        let chatId = fail.message.chatId
        var didReplace = replaceMessageIfExists(chatId: chatId, id: fail.oldMessageId, newMessage: fail.message)
        if !didReplace, let localId = localIdByTempMessageId[fail.oldMessageId],
           let link = pendingByLocalId[localId] {
            didReplace = replaceMessageIfExists(chatId: chatId, id: link.placeholderId, newMessage: fail.message)
        }
        if !didReplace {
            _ = replaceMessageIfExists(chatId: chatId, id: fail.message.id, newMessage: fail.message)
        }

        coalesceOutgoingDuplicates(chatId: chatId, localId: localIdByTempMessageId[fail.oldMessageId], keepMessageId: fail.message.id, fallbackMessage: fail.message)

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
        if let sid = msg.sendingId,
           let localId = localIdBySendingId[sid],
           var link = pendingByLocalId[localId] {
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
#if DEBUG
            print("[Reconcile] updateNewMessage matched sending_id=\(sid) placeholderId=\(placeholderId)")
#endif
            coalesceOutgoingDuplicates(chatId: chatId, localId: localId, keepMessageId: merged.id, fallbackMessage: merged)
            return true
        }

        let messageText = msg.rawText ?? msg.text
        let candidates = pendingByLocalId.values.filter {
            $0.chatId == msg.chatId &&
            abs($0.date - msg.date) <= 10 &&
            $0.text == messageText
        }
        guard candidates.count == 1, let match = candidates.first else { return false }
        guard var link = pendingByLocalId[match.localId] else { return false }

        let chatId = link.chatId
        let placeholderId = link.placeholderId
        var merged = msg
        merged.localId = link.localId
        merged.sendingId = merged.sendingId ?? link.sendingId

        replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: merged)

        link.placeholderId = merged.id
        pendingByLocalId[link.localId] = link
        localIdByTempMessageId[merged.id] = link.localId
        serverMessageIdByLocalId[link.localId] = merged.id

        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
#if DEBUG
        print("[Reconcile] updateNewMessage matched fallback placeholderId=\(placeholderId)")
#endif
        coalesceOutgoingDuplicates(chatId: chatId, localId: link.localId, keepMessageId: merged.id, fallbackMessage: merged)
        return true
    }

    func coalesceOutgoingDuplicates(
        chatId: Int64,
        localId: UUID?,
        keepMessageId: Int64,
        fallbackMessage: TGMessage?
    ) {
        guard var arr = messagesByChatId[chatId] else { return }
        var idsToRemove: [Int64] = []

        if let localId {
            idsToRemove = arr.filter { $0.localId == localId && $0.id != keepMessageId }.map(\.id)
        } else if let fallbackMessage {
            let fallbackText = fallbackMessage.rawText ?? fallbackMessage.text
            let candidates = arr.filter {
                $0.isOutgoing &&
                ($0.rawText ?? $0.text) == fallbackText &&
                abs($0.date - fallbackMessage.date) <= 10 &&
                ($0.sendState != .sent)
            }
            if candidates.count == 1, let candidate = candidates.first, candidate.id != keepMessageId {
                idsToRemove = [candidate.id]
            }
        }

        guard !idsToRemove.isEmpty else { return }
        idsToRemove.forEach { id in
            arr.removeAll { $0.id == id }
#if DEBUG
            print("[Deduper] removed duplicate id=\(id) keep=\(keepMessageId) localId=\(localId?.uuidString ?? "nil")")
#endif
            self.deleteMessages(chatId: chatId, messageIds: [id]) // deleteMessages(chatId:messageIds:)
        }
        messagesByChatId[chatId] = arr
    }
}
