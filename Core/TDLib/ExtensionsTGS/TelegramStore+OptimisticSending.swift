//  TelegramStore+OptimisticSending.swift
//  Aurora
//

import Foundation
import AppKit

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

    @MainActor
    func startPendingCleanupTimer() {
        pendingCleanupTimer?.invalidate()
        pendingCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupExpiredPendingItems()
        }
    }

    func restorePendingMessagesFromDatabase() {
        guard let repo = databaseRepository else { return }
        let pendingMessages = repo.fetchPendingMessages()
        guard !pendingMessages.isEmpty else { return }

        let now = Int(Date().timeIntervalSince1970)
        for var message in pendingMessages {
            var needsPersist = false
            if message.localId == nil {
                message.localId = UUID()
                needsPersist = true
            }
            if message.sendingId == nil {
                message.sendingId = makeSendingId()
                needsPersist = true
            }
            guard let localId = message.localId else { continue }
            if needsPersist {
                if !replaceMessageIfExists(chatId: message.chatId, id: message.id, newMessage: message) {
                    persistMessage(message)
                }
            }

            let link = PendingLink(
                chatId: message.chatId,
                placeholderId: message.id,
                localId: localId,
                sendingId: message.sendingId ?? makeSendingId(),
                text: message.rawText ?? message.text,
                date: message.date,
                isOutgoing: message.isOutgoing,
                senderUserId: message.senderUserId,
                replyToMessageId: message.replyToMessageId,
                contentType: message.contentType,
                rawText: message.rawText,
                entities: message.entities,
                attachmentFingerprint: attachmentFingerprint(for: message),
                retryCount: message.retryCount,
                nextRetryAt: message.nextRetryAt
            )

            if isPendingExpired(link: link, now: now) {
                finalizePending(localId: localId, result: .failed(reason: "Send timed out", canRetry: true, message: nil))
                continue
            }

            pendingByLocalId[localId] = link
            localIdByTempMessageId[message.id] = localId
            if let sendingId = message.sendingId {
                localIdBySendingId[sendingId] = localId
            }
        }
    }

    func attachmentFingerprint(for message: TGMessage) -> String? {
        guard message.contentType != "messageText" else { return nil }
        return message.contentType
    }

    func pendingFallbackWindowSeconds() -> Int {
        let isActive = NSApp?.isActive ?? true
        return isActive ? 2 : 10
    }

    func isPendingExpired(link: PendingLink, now: Int) -> Bool {
        now - link.date >= pendingTtlSeconds
    }

    func cleanupExpiredPendingItems() {
        let now = Int(Date().timeIntervalSince1970)
        let expired = pendingByLocalId.values.filter { isPendingExpired(link: $0, now: now) }
        for link in expired {
            finalizePending(localId: link.localId, result: .failed(reason: "Send timed out", canRetry: true, message: nil))
        }
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
            replyToMessageId: nil,
            localId: localId,
            sendingId: sendingId,
            editedAt: nil,
            canRetry: false,
            retryCount: 0,
            nextRetryAt: nil
        )

        optimisticInsertMessage(pending)

        pendingByLocalId[localId] = PendingLink(
            chatId: chatId,
            placeholderId: placeholderId,
            localId: localId,
            sendingId: sendingId,
            text: clean,
            date: now,
            isOutgoing: true,
            senderUserId: myUserId,
            replyToMessageId: nil,
            contentType: pending.contentType,
            rawText: pending.rawText,
            entities: pending.entities,
            attachmentFingerprint: attachmentFingerprint(for: pending),
            retryCount: 0,
            nextRetryAt: nil
        )
        localIdByTempMessageId[placeholderId] = localId
        localIdBySendingId[sendingId] = localId
        if let link = pendingByLocalId[localId] {
            logPendingStateChange(state: "pending", link: link, messageId: placeholderId)
        }

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
        markMessageSending(localId: localId)
    }

    func sendTextWithExistingLocalId(chatId: Int64, text: String, localId: UUID, sendingId: Int32) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard var link = pendingByLocalId[localId] else { return }

        link.sendingId = sendingId
        pendingByLocalId[localId] = link
        localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
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
        markMessageSending(localId: localId)
    }

    func _retrySend_impl(message: TGMessage) {
        guard message.chatId != 0 else { return }

        let localId = message.localId ?? pendingByLocalId.first(where: { $0.value.placeholderId == message.id })?.key
        let sendingId = makeSendingId()

        if let localId, var link = pendingByLocalId[localId] {
            link.sendingId = sendingId
            link.retryCount += 1
            link.nextRetryAt = nil
            pendingByLocalId[localId] = link
            localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
            localIdBySendingId[sendingId] = localId
        }

        if message.canRetry, message.id > 0 {
            markMessageSending(chatId: message.chatId, id: message.id, localId: localId, sendingId: sendingId)

            let req: [String: Any] = [
                "@type": "resendMessages",
                "@extra": "resend:\(message.chatId):\(message.id):\(UUID().uuidString)",
                "chat_id": message.chatId,
                "message_ids": [message.id]
            ]
            sendJSON(req)
            return
        }

        if let localId {
            sendTextWithExistingLocalId(chatId: message.chatId, text: message.text, localId: localId, sendingId: sendingId)
        } else {
            _sendText_impl(chatId: message.chatId, text: message.text)
        }
    }

    func _cancelPending_impl(message: TGMessage) {
        let localId = message.localId ?? localIdByTempMessageId[message.id]
        guard let localId, pendingByLocalId[localId] != nil else { return }
        finalizePending(localId: localId, result: .canceled)
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
            case .sending:
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

    func markMessageSending(chatId: Int64, id: Int64, localId: UUID?, sendingId: Int32?) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        var m = arr[idx]
        m.sendState = .sending
        m.canRetry = false
        if let localId { m.localId = localId }
        if let sendingId { m.sendingId = sendingId }
        if let localId, let link = pendingByLocalId[localId] {
            m.retryCount = link.retryCount
            m.nextRetryAt = link.nextRetryAt
        }
        arr[idx] = m
        messagesByChatId[chatId] = sortChronological(arr)
        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        persistMessage(m)
        if let localId, let link = pendingByLocalId[localId] {
            logPendingStateChange(state: "sending", link: link, messageId: id)
        }
    }

    func markMessageSending(localId: UUID) {
        guard let link = pendingByLocalId[localId] else { return }
        markMessageSending(chatId: link.chatId, id: link.placeholderId, localId: localId, sendingId: link.sendingId)
    }

    // MARK: - Reconciliation with TDLib

    enum PendingFinalizeResult {
        case sent(message: TGMessage)
        case failed(reason: String, canRetry: Bool, message: TGMessage?)
        case canceled
    }

    func finalizePending(localId: UUID, result: PendingFinalizeResult) {
        guard let link = pendingByLocalId[localId] else { return }
        let chatId = link.chatId
        let placeholderId = link.placeholderId

        func findLocalMessage() -> TGMessage? {
            guard let arr = messagesByChatId[chatId] else { return nil }
            if let match = arr.first(where: { $0.localId == localId }) { return match }
            return arr.first(where: { $0.id == placeholderId })
        }

        var finalMessage: TGMessage? = nil
        var keepServerLink = false

        switch result {
        case .sent(let message):
            var sent = message
            sent.sendState = .sent
            sent.canRetry = false
            sent.localId = localId
            sent.sendingId = sent.sendingId ?? link.sendingId
            sent.retryCount = link.retryCount
            sent.nextRetryAt = nil
            replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: sent)
            finalMessage = sent
            keepServerLink = true

        case .failed(let reason, let canRetry, let message):
            var failed = message ?? findLocalMessage() ?? TGMessage(
                id: placeholderId,
                chatId: chatId,
                date: link.date,
                isOutgoing: true,
                senderUserId: link.senderUserId,
                text: link.text,
                contentType: link.contentType,
                rawText: link.rawText,
                entities: link.entities,
                sendState: .failed(errorText: reason),
                replyToMessageId: link.replyToMessageId,
                localId: localId,
                sendingId: link.sendingId,
                editedAt: nil,
                canRetry: canRetry,
                retryCount: link.retryCount,
                nextRetryAt: link.nextRetryAt
            )
            failed.sendState = .failed(errorText: reason)
            failed.canRetry = canRetry
            failed.localId = localId
            failed.sendingId = failed.sendingId ?? link.sendingId
            failed.retryCount = link.retryCount
            failed.nextRetryAt = link.nextRetryAt
            replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: failed)
            finalMessage = failed

        case .canceled:
            _ = removeMessageById(chatId: chatId, id: placeholderId)
        }

        pendingByLocalId.removeValue(forKey: localId)
        localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
        localIdByTempMessageId = localIdByTempMessageId.filter { $0.value != localId }

        if keepServerLink, let finalMessage {
            serverMessageIdByLocalId[localId] = finalMessage.id
        } else {
            serverMessageIdByLocalId.removeValue(forKey: localId)
        }

        if let finalMessage {
            keepOptimisticChatPreviewIfNeeded(chatId: chatId)
            coalesceOutgoingDuplicates(chatId: chatId, localId: localId, keepMessageId: finalMessage.id, fallbackMessage: finalMessage)
            persistMessage(finalMessage)
        }

        if let finalMessage, placeholderId != finalMessage.id {
            if var arr = messagesByChatId[chatId], arr.contains(where: { $0.id == placeholderId }) {
                arr.removeAll { $0.id == placeholderId }
                messagesByChatId[chatId] = arr
            }
            databaseRepository?.deleteMessages(chatId: chatId, messageIds: [placeholderId])
#if DEBUG
            if let repo = databaseRepository, repo.messageExists(chatId: chatId, messageId: placeholderId) {
                assertionFailure("[Pending] placeholder row leak chatId=\(chatId) id=\(placeholderId)")
            }
#endif
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
        logPendingTransition(result: result, link: link, message: finalMessage)
    }

    func logPendingTransition(result: PendingFinalizeResult, link: PendingLink, message: TGMessage?) {
        let serverId = message?.id ?? serverMessageIdByLocalId[link.localId] ?? 0
        let sendingId = message?.sendingId ?? link.sendingId
        let label: String
        switch result {
        case .sent:
            label = "sent"
        case .failed:
            label = "failed"
        case .canceled:
            label = "canceled"
        }
        print("[Pending] \(label) localId=\(link.localId.uuidString) sendingId=\(sendingId) placeholderId=\(link.placeholderId) serverMessageId=\(serverId) retry=\(link.retryCount)")
    }

    func logPendingStateChange(state: String, link: PendingLink, messageId: Int64) {
        let serverId = serverMessageIdByLocalId[link.localId] ?? 0
        print("[Pending] \(state) localId=\(link.localId.uuidString) sendingId=\(link.sendingId) placeholderId=\(link.placeholderId) serverMessageId=\(serverId) messageId=\(messageId) retry=\(link.retryCount)")
    }

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

    func bindPendingToServerMessage(localId: UUID, msg: TGMessage, logLabel: String) -> Bool {
        guard var link = pendingByLocalId[localId] else { return false }

        if case .sent = msg.sendState {
            finalizePending(localId: localId, result: .sent(message: msg))
            return true
        }

        let chatId = link.chatId
        let placeholderId = link.placeholderId

        var merged = msg
        merged.localId = localId
        merged.sendingId = merged.sendingId ?? link.sendingId
        merged.retryCount = link.retryCount
        merged.nextRetryAt = link.nextRetryAt
        if merged.replyToMessageId == nil { merged.replyToMessageId = link.replyToMessageId }
        if merged.rawText == nil { merged.rawText = link.rawText }
        if merged.entities.isEmpty { merged.entities = link.entities }
        if case .pending = merged.sendState {
            merged.sendState = .sending
        }

        replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: merged)
        _ = removeMessageById(chatId: chatId, id: placeholderId)

        link.placeholderId = merged.id
        link.sendingId = merged.sendingId ?? link.sendingId
        pendingByLocalId[localId] = link
        localIdByTempMessageId.removeValue(forKey: placeholderId)
        localIdByTempMessageId[merged.id] = localId
        serverMessageIdByLocalId[localId] = merged.id

        keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        coalesceOutgoingDuplicates(chatId: chatId, localId: localId, keepMessageId: merged.id, fallbackMessage: merged)
        persistMessage(merged)

#if DEBUG
        print("[Reconcile] \(logLabel) localId=\(localId.uuidString) placeholderId=\(placeholderId) -> messageId=\(merged.id)")
#endif
        return true
    }

    func reconcileFunctionResponseSend(extra: String?, msg: TGMessage) -> Bool {
        guard let extra, extra.hasPrefix("send:") else { return false }
        let suffix = String(extra.dropFirst("send:".count))
        guard let localId = UUID(uuidString: suffix),
              pendingByLocalId[localId] != nil else { return false }

        pendingMetrics.reconcileByFunctionResponseExtra += 1
        return bindPendingToServerMessage(localId: localId, msg: msg, logLabel: "functionResponse")
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

    func resolvePendingLocalId(for message: TGMessage, oldMessageId: Int64) -> UUID? {
        if let localId = localIdByTempMessageId[oldMessageId] { return localId }
        if let sendingId = message.sendingId, let localId = localIdBySendingId[sendingId] { return localId }
        if let localId = serverMessageIdByLocalId.first(where: { $0.value == message.id })?.key { return localId }
        return nil
    }

    func handleSendSucceeded(_ succ: SendSucceeded) {
        var final = succ.message
        final.sendState = .sent
        final.canRetry = false

        if let localId = resolvePendingLocalId(for: final, oldMessageId: succ.oldMessageId),
           pendingByLocalId[localId] != nil {
            finalizePending(localId: localId, result: .sent(message: final))
            return
        }

        let chatId = final.chatId
        let replaced = replaceMessageIfExists(chatId: chatId, id: succ.oldMessageId, newMessage: final)
        if !replaced {
            _ = replaceMessageIfExists(chatId: chatId, id: final.id, newMessage: final)
        }
        if succ.oldMessageId != final.id {
            _ = removeMessageById(chatId: chatId, id: succ.oldMessageId)
        }
        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func handleSendFailed(_ fail: SendFailed) {
        var failed = fail.message
        failed.sendState = .failed(errorText: fail.errorText)
        failed.canRetry = fail.canRetry

        if let localId = resolvePendingLocalId(for: failed, oldMessageId: fail.oldMessageId),
           pendingByLocalId[localId] != nil {
            finalizePending(localId: localId, result: .failed(reason: fail.errorText, canRetry: fail.canRetry, message: failed))
            return
        }

        let chatId = failed.chatId
        let didReplace = replaceMessageIfExists(chatId: chatId, id: fail.oldMessageId, newMessage: failed)
        if !didReplace {
            _ = replaceMessageIfExists(chatId: chatId, id: failed.id, newMessage: failed)
        }
        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func pendingFallbackMatches(link: PendingLink, msg: TGMessage, windowSeconds: Int) -> Bool {
        guard link.chatId == msg.chatId else { return false }
        guard link.isOutgoing == msg.isOutgoing else { return false }
        guard link.senderUserId == msg.senderUserId else { return false }
        guard link.replyToMessageId == msg.replyToMessageId else { return false }
        guard link.contentType == msg.contentType else { return false }
        guard link.entities == msg.entities else { return false }
        guard link.attachmentFingerprint == attachmentFingerprint(for: msg) else { return false }

        let messageText = msg.rawText ?? msg.text
        let linkText = link.rawText ?? link.text
        guard linkText == messageText else { return false }
        return abs(link.date - msg.date) <= windowSeconds
    }

    func tryReconcileOutgoingPendingMessage(_ msg: TGMessage) -> Bool {
        guard msg.isOutgoing else { return false }
        if let sid = msg.sendingId,
           let localId = localIdBySendingId[sid],
           pendingByLocalId[localId] != nil {
            pendingMetrics.reconcileBySendingId += 1
            return bindPendingToServerMessage(localId: localId, msg: msg, logLabel: "sendingId")
        }

        let window = pendingFallbackWindowSeconds()
        let candidates = pendingByLocalId.values.filter { pendingFallbackMatches(link: $0, msg: msg, windowSeconds: window) }

        if candidates.count > 1 {
            pendingMetrics.fallbackAmbiguous += 1
#if DEBUG
            print("[Reconcile] fallback ambiguous chatId=\(msg.chatId) count=\(candidates.count)")
#endif
            return false
        }

        guard let match = candidates.first else { return false }
        pendingMetrics.reconcileByFallback += 1
        return bindPendingToServerMessage(localId: match.localId, msg: msg, logLabel: "fallback")
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
        pendingMetrics.coalesceRemovedCount += idsToRemove.count
        idsToRemove.forEach { id in
            arr.removeAll { $0.id == id }
#if DEBUG
            print("[Deduper] removed duplicate id=\(id) keep=\(keepMessageId) localId=\(localId?.uuidString ?? "nil")")
#endif
            if id > 0 {
                self.deleteMessages(chatId: chatId, messageIds: [id]) // deleteMessages(chatId:messageIds:)
            }
        }
        messagesByChatId[chatId] = arr
    }
}
