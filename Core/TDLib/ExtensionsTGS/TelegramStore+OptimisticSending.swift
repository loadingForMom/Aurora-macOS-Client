//  TelegramStore+OptimisticSending.swift
//  Aurora
//

import Foundation
import AppKit
import os

extension TelegramStore {

    private func enqueueChatLastUpdate(for message: TGMessage) async {
        let preview: String
        switch message.sendState {
        case .pending, .sending:
            preview = "You: (sending…) \(message.previewText)"
        case .failed:
            preview = "You: (failed) \(message.previewText)"
        case .sent:
            preview = message.previewText
        }
        await databaseBatchWriter.enqueue(
            [
                .updateChatLastMessage(chatId: message.chatId, messageId: message.id, preview: preview, date: message.date),
                .upsertChatLastMessage(chatId: message.chatId, messageId: message.id, preview: preview, date: message.date)
            ]
        )
    }

    private func replaceMessage(chatId: Int64, oldId: Int64, newMessage: TGMessage) async {
        _ = await messageStore.mergeMessages(
            chatId: chatId,
            messages: [newMessage],
            windowLimit: historyWindowLimitByChatId[chatId] ?? 160
        )
        await databaseBatchWriter.enqueue(.upsertMessage(newMessage))
        if oldId != newMessage.id {
            _ = await messageStore.applyDelete(chatId: chatId, messageIds: [oldId])
            await databaseBatchWriter.enqueue(.deleteMessages(chatId: chatId, messageIds: [oldId]))
        }
    }

    private func replaceMessageIfExists(chatId: Int64, id: Int64, newMessage: TGMessage) async -> Bool {
        guard databaseRepository.messageExists(chatId: chatId, messageId: id) else { return false }
        _ = await messageStore.mergeMessages(
            chatId: chatId,
            messages: [newMessage],
            windowLimit: historyWindowLimitByChatId[chatId] ?? 160
        )
        await databaseBatchWriter.enqueue(.upsertMessage(newMessage))
        return true
    }

    private func removeMessageById(chatId: Int64, id: Int64) async {
        _ = await messageStore.applyDelete(chatId: chatId, messageIds: [id])
        await databaseBatchWriter.enqueue(.deleteMessages(chatId: chatId, messageIds: [id]))
    }

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

    func startPendingCleanupTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingCleanupTimer?.invalidate()
            self.pendingCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.cleanupExpiredPendingItems()
            }
        }
    }

    func restorePendingMessagesFromDatabase() {
        let pendingMessages = databaseRepository.fetchPendingMessages()
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
                Task {
                    if !(await replaceMessageIfExists(chatId: message.chatId, id: message.id, newMessage: message)) {
                        await databaseBatchWriter.enqueue(.upsertMessage(message))
                    }
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
                Task { await finalizePending(localId: localId, result: .failed(reason: "Send timed out", canRetry: true, message: nil)) }
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
            Task { await finalizePending(localId: link.localId, result: .failed(reason: "Send timed out", canRetry: true, message: nil)) }
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
        enqueueTDLibRequest(req, typeOverride: "sendMessage", priority: .high)
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
        enqueueTDLibRequest(req, typeOverride: "sendMessage", priority: .high)
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
            enqueueTDLibRequest(req, typeOverride: "resendMessages")
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
        Task { await finalizePending(localId: localId, result: .canceled) }
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
        enqueueTDLibRequest(req, typeOverride: "deleteMessages")
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
        enqueueTDLibRequest(req, typeOverride: "editMessageText")
    }

    func optimisticInsertMessage(_ msg: TGMessage) {
        Task {
            _ = await messageStore.mergeMessages(
                chatId: msg.chatId,
                messages: [msg],
                windowLimit: historyWindowLimitByChatId[msg.chatId] ?? 160
            )
            await databaseBatchWriter.enqueue(.upsertMessage(msg))
            await enqueueChatLastUpdate(for: msg)
        }
    }

    func markMessagePending(chatId: Int64, id: Int64) {
        Task {
            guard var m = databaseRepository.fetchMessage(chatId: chatId, messageId: id) else { return }
            m.sendState = .pending
            m.canRetry = false
            _ = await messageStore.mergeMessages(
                chatId: chatId,
                messages: [m],
                windowLimit: historyWindowLimitByChatId[chatId] ?? 160
            )
            await databaseBatchWriter.enqueue(.upsertMessage(m))
            await enqueueChatLastUpdate(for: m)
        }
    }

    func markMessageSending(chatId: Int64, id: Int64, localId: UUID?, sendingId: Int32?) {
        Task {
            guard var m = databaseRepository.fetchMessage(chatId: chatId, messageId: id) else { return }
            m.sendState = .sending
            m.canRetry = false
            if let localId { m.localId = localId }
            if let sendingId { m.sendingId = sendingId }
            if let localId, let link = pendingByLocalId[localId] {
                m.retryCount = link.retryCount
                m.nextRetryAt = link.nextRetryAt
            }
            _ = await messageStore.mergeMessages(
                chatId: chatId,
                messages: [m],
                windowLimit: historyWindowLimitByChatId[chatId] ?? 160
            )
            await databaseBatchWriter.enqueue(.upsertMessage(m))
            await enqueueChatLastUpdate(for: m)
            if let localId, let link = pendingByLocalId[localId] {
                logPendingStateChange(state: "sending", link: link, messageId: id)
            }
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

    func finalizePending(localId: UUID, result: PendingFinalizeResult) async {
        guard let link = pendingByLocalId[localId] else { return }
        let chatId = link.chatId
        let placeholderId = link.placeholderId

        func findLocalMessage() -> TGMessage? {
            databaseRepository.fetchMessage(chatId: chatId, messageId: placeholderId)
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
            if !(await replaceMessageIfExists(chatId: chatId, id: sent.id, newMessage: sent)) {
                await replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: sent)
            }
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
            await replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: failed)
            finalMessage = failed

        case .canceled:
            await removeMessageById(chatId: chatId, id: placeholderId)
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
            await enqueueChatLastUpdate(for: finalMessage)
            await coalesceOutgoingDuplicates(chatId: chatId, localId: localId, keepMessageId: finalMessage.id, fallbackMessage: finalMessage)
        }

        await updateChatLastFromLocalTimeline(chatId: chatId)
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
        log.debug("pending \(label) localId=\(link.localId.uuidString) sendingId=\(sendingId) placeholderId=\(link.placeholderId) serverMessageId=\(serverId) retry=\(link.retryCount)")
    }

    func logPendingStateChange(state: String, link: PendingLink, messageId: Int64) {
        let serverId = serverMessageIdByLocalId[link.localId] ?? 0
        log.debug("pending \(state) localId=\(link.localId.uuidString) sendingId=\(link.sendingId) placeholderId=\(link.placeholderId) serverMessageId=\(serverId) messageId=\(messageId) retry=\(link.retryCount)")
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

    func bindPendingToServerMessage(localId: UUID, msg: TGMessage, logLabel: String) async -> Bool {
        guard var link = pendingByLocalId[localId] else { return false }

        if case .sent = msg.sendState {
            await finalizePending(localId: localId, result: .sent(message: msg))
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

        await replaceMessage(chatId: chatId, oldId: placeholderId, newMessage: merged)
        await removeMessageById(chatId: chatId, id: placeholderId)

        link.placeholderId = merged.id
        link.sendingId = merged.sendingId ?? link.sendingId
        pendingByLocalId[localId] = link
        localIdByTempMessageId.removeValue(forKey: placeholderId)
        localIdByTempMessageId[merged.id] = localId
        serverMessageIdByLocalId[localId] = merged.id

        await enqueueChatLastUpdate(for: merged)
        await coalesceOutgoingDuplicates(chatId: chatId, localId: localId, keepMessageId: merged.id, fallbackMessage: merged)

#if DEBUG
        log.debug("reconcile \(logLabel) localId=\(localId.uuidString) placeholderId=\(placeholderId) -> messageId=\(merged.id)")
#endif
        return true
    }

    func reconcileFunctionResponseSend(extra: String?, msg: TGMessage) async -> Bool {
        guard let extra, extra.hasPrefix("send:") else { return false }
        let suffix = String(extra.dropFirst("send:".count))
        guard let localId = UUID(uuidString: suffix),
              pendingByLocalId[localId] != nil else { return false }

        pendingMetrics.reconcileByFunctionResponseExtra += 1
        return await bindPendingToServerMessage(localId: localId, msg: msg, logLabel: "functionResponse")
    }

    func handleFunctionResponseMessage(_ resp: FunctionResponseMessage) async {
        let msg = resp.message

        let reconciledByFunctionResponse = await reconcileFunctionResponseSend(extra: resp.extra, msg: msg)
        let reconciled: Bool
        if reconciledByFunctionResponse {
            reconciled = true
        } else {
            reconciled = await tryReconcileOutgoingPendingMessage(msg)
        }

    #if DEBUG
        if let extra = resp.extra, extra.hasPrefix("send:") {
            log.debug("send response extra=\(extra, privacy: .public) reconciled=\(reconciled, privacy: .public)")
        }
    #endif

        if reconciled {
            await updateChatLastFromLocalTimeline(chatId: msg.chatId)
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

    func handleSendSucceeded(_ succ: SendSucceeded) async {
        var final = succ.message
        final.sendState = .sent
        final.canRetry = false

        if let localId = resolvePendingLocalId(for: final, oldMessageId: succ.oldMessageId),
           pendingByLocalId[localId] != nil {
            await finalizePending(localId: localId, result: .sent(message: final))
            return
        }

        let chatId = final.chatId
        let replaced = await replaceMessageIfExists(chatId: chatId, id: succ.oldMessageId, newMessage: final)
        if !replaced {
            _ = await replaceMessageIfExists(chatId: chatId, id: final.id, newMessage: final)
        }
        if succ.oldMessageId != final.id {
            await removeMessageById(chatId: chatId, id: succ.oldMessageId)
        }
        await updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func handleSendFailed(_ fail: SendFailed) async {
        var failed = fail.message
        failed.sendState = .failed(errorText: fail.errorText)
        failed.canRetry = fail.canRetry

        if let localId = resolvePendingLocalId(for: failed, oldMessageId: fail.oldMessageId),
           pendingByLocalId[localId] != nil {
            await finalizePending(localId: localId, result: .failed(reason: fail.errorText, canRetry: fail.canRetry, message: failed))
            return
        }

        let chatId = failed.chatId
        let didReplace = await replaceMessageIfExists(chatId: chatId, id: fail.oldMessageId, newMessage: failed)
        if !didReplace {
            _ = await replaceMessageIfExists(chatId: chatId, id: failed.id, newMessage: failed)
        }
        await updateChatLastFromLocalTimeline(chatId: chatId)
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

    func tryReconcileOutgoingPendingMessage(_ msg: TGMessage) async -> Bool {
        guard msg.isOutgoing else { return false }
        if let sid = msg.sendingId,
           let localId = localIdBySendingId[sid],
           pendingByLocalId[localId] != nil {
            pendingMetrics.reconcileBySendingId += 1
            return await bindPendingToServerMessage(localId: localId, msg: msg, logLabel: "sendingId")
        }

        let window = pendingFallbackWindowSeconds()
        let candidates = pendingByLocalId.values.filter { pendingFallbackMatches(link: $0, msg: msg, windowSeconds: window) }

        if candidates.count > 1 {
            pendingMetrics.fallbackAmbiguous += 1
#if DEBUG
            log.debug("reconcile fallback ambiguous chatId=\(msg.chatId) count=\(candidates.count)")
#endif
            return false
        }

        guard let match = candidates.first else { return false }
        pendingMetrics.reconcileByFallback += 1
        return await bindPendingToServerMessage(localId: match.localId, msg: msg, logLabel: "fallback")
    }

    func coalesceOutgoingDuplicates(
        chatId: Int64,
        localId: UUID?,
        keepMessageId: Int64,
        fallbackMessage _: TGMessage?
    ) async {
        guard let localId else { return }
        pendingMetrics.coalesceRemovedCount += 1
        await databaseBatchWriter.enqueue(.deleteMessagesByLocalId(chatId: chatId, localId: localId, keepingMessageId: keepMessageId))
#if DEBUG
        log.debug("deduper removed duplicates keep=\(keepMessageId) localId=\(localId.uuidString)")
#endif
    }
}
