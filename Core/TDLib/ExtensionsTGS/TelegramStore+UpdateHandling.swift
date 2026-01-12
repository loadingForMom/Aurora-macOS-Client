//  TelegramStore+UpdateHandling.swift
//  Aurora
//

import Foundation
import os

extension TelegramStore {

    func handleUpdate(_ upd: String) async {
        if let st = parseAuthState(from: upd) {
            let previous = authState
            await MainActor.run {
                authState = st
                if st == "authorizationStateClosed" {
                    resetSessionState()
                } else if previous == "authorizationStateReady", st != "authorizationStateReady" {
                    resetSessionState()
                }
            }
            log.info("auth state changed to \(st, privacy: .public)")
        }

        if let (chatId, lastMessage) = parseUpdateChatLastMessage(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateChatLastMessage", chatId: chatId, messageId: lastMessage.id)
#endif
            await applyChatLastMessageUpdate(chatId: chatId, lastMessageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
            await databaseBatchWriter.enqueue(.upsertMessage(lastMessage))
            await databaseBatchWriter.enqueue(.upsertChatLastMessage(chatId: chatId, messageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date))
            await keepOptimisticChatPreviewIfNeeded(chatId: chatId)
        }

        if let (chatId, lastReadInboxMessageId, unreadCount) = parseUpdateChatReadInbox(upd) {
            await applyChatReadInboxUpdate(chatId: chatId, lastReadInboxMessageId: lastReadInboxMessageId, unreadCount: unreadCount)
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
        
        if authState == "authorizationStateWaitEncryptionKey" {
            if let key = getOrCreateDatabaseEncryptionKey() {
                let req: [String: Any] = [
                    "@type": "checkDatabaseEncryptionKey",
                    "encryption_key": key
                ]
                sendJSON(req)
            } else {
                log.error("Failed to resolve TDLib encryption key during auth")
            }
        }

        if let (id, title) = parseUpdateChatTitle(upd) {
            await databaseBatchWriter.enqueue(.updateChatTitle(chatId: id, title: title))
        }

        if let (chatId, order) = parseUpdateChatPosition(upd) {
            await databaseBatchWriter.enqueue(.updateChatOrder(chatId: chatId, order: order))
        }

        if let (u, photoFileId, photoPath) = parseUpdateUser(upt: upd) {
            userCache[u.id] = u
            await databaseBatchWriter.enqueue(.upsertUser(u))

            if let meId = myUserId, meId == u.id {
                if let p = photoPath {
                    await MainActor.run { myProfilePhotoPath = p }
                }
                if let fid = photoFileId {
                    myPhotoFileId = fid
                    downloadMyPhotoIfNeeded(fileId: fid)
                }
            }
        }

        if let path = parseUpdateFilePathIfMyPhoto(upd) {
            await MainActor.run { myProfilePhotoPath = path }
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
            userCache[user.id] = user
            await databaseBatchWriter.enqueue(.upsertUser(user))
        }

        // Sending lifecycle updates
        if let succ = parseUpdateMessageSendSucceeded(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageSendSucceeded", chatId: succ.message.chatId, messageId: succ.message.id)
#endif
            await handleSendSucceeded(succ)
        }

        if let fail = parseUpdateMessageSendFailed(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageSendFailed", chatId: fail.message.chatId, messageId: fail.message.id)
#endif
            await handleSendFailed(fail)
        }

        // Edit / content changes
        if let edited = parseUpdateMessageEdited(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageEdited", chatId: edited.chatId, messageId: edited.messageId)
#endif
            await applyMessageEdited(chatId: edited.chatId, messageId: edited.messageId, editDate: edited.editDate)
        }

        if let content = parseUpdateMessageContent(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageContent", chatId: content.chatId, messageId: content.messageId)
#endif
            await applyMessageContentChanged(chatId: content.chatId, messageId: content.messageId, newContent: content.newContent)
        }

        // Deletions
        if let del = parseUpdateDeleteMessages(upd) {
#if DEBUG
            del.messageIds.forEach { debugLogMessageEvent(label: "updateDeleteMessages", chatId: del.chatId, messageId: $0) }
#endif
            await applyMessagesDeleted(chatId: del.chatId, messageIds: del.messageIds)
        }

        // New messages
        if let (chatId, msg) = parseUpdateNewMessage(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateNewMessage", chatId: chatId, messageId: msg.id)
#endif
            requestUserIfNeeded(msg.senderUserId)

            if await tryReconcileOutgoingPendingMessage(msg) {
#if DEBUG
                log.debug("updateNewMessage reconciled -> skip append")
#endif
            } else {
                await databaseBatchWriter.enqueue(.upsertMessage(msg))
            }

            await updateChatLastFromLocalTimeline(chatId: chatId)
        }
    }

    func handleResponse(_ resp: String) async {
        if let err = parseTdError(resp) {
            log.error("tdlib error code=\(err.code, privacy: .public) message=\(err.message, privacy: .public) extra=\(err.extra ?? "nil", privacy: .public)")
            return
        }

        if let ids = parseChatsResponse(resp) {
            for id in ids {
                td.send(#"{"@type":"getChat","chat_id":\#(id)}"#)
            }
        }

        if let (chat, lastMessage, smallId, bigId, bestPath) = parseChatObject(resp) {
            await databaseBatchWriter.enqueue(.upsertChat(chat))
            if let lastMessage {
                await databaseBatchWriter.enqueue(.upsertMessage(lastMessage))
                await databaseBatchWriter.enqueue(.upsertChatLastMessage(chatId: chat.id, messageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date))
            }

            if let p = bestPath {
                chatAvatarPathByChatId[chat.id] = p
            }

            registerChatAvatar(chatId: chat.id, smallFileId: smallId, bigFileId: bigId, initialBestPath: bestPath)

            if selectedChatId == nil {
                await MainActor.run { selectedChatId = chat.id }
                loadInitialHistory(chatId: chat.id)
            }
        }

        // MARK: - Current user (me) + profile photo

        if let (me, photoFileId, photoPath) = parseMeUserResponse(resp) {
            await MainActor.run { myUserId = me.id }
            userCache[me.id] = me
            await databaseBatchWriter.enqueue(.upsertUser(me))

            if let p = photoPath {
                await MainActor.run { myProfilePhotoPath = p }
            }

            if let fid = photoFileId {
                myPhotoFileId = fid
                downloadMyPhotoIfNeeded(fileId: fid)
            }
        }

        if let user = parseUserObject(resp) {
            userCache[user.id] = user
            await databaseBatchWriter.enqueue(.upsertUser(user))
        }

        if let storage = parseStorageStatisticsAny(resp) {
            applyStorageStatistics(storage)
        }

        // Response message with @extra
        if let msgResponse = parseMessageFunctionResponse(resp) {
            await handleFunctionResponseMessage(msgResponse)
        }

        // History responses
        if let res = parseMessagesResponse(resp), let job = historyJobs[res.extra] {
            let currentGeneration = historyGenerationByChatId[job.chatId] ?? 0
            guard currentGeneration == job.generation else {
                // Discard stale history so older responses can't replace a newer window.
#if DEBUG
                log.debug("history discarded chatId=\(job.chatId, privacy: .public) gen=\(job.generation, privacy: .public) current=\(currentGeneration, privacy: .public)")
                log.debug("history discard extra=\(res.extra, privacy: .public) kind=\(String(describing: job.kind), privacy: .public)")
#endif
                historyJobs.removeValue(forKey: res.extra)
                if selectedChatId == job.chatId {
                    let loading = historyJobs.values.contains(where: { $0.chatId == job.chatId })
                    await MainActor.run { isLoadingHistory = loading }
                }
                return
            }
#if DEBUG
            let minId = res.messages.min(by: { $0.id < $1.id })?.id
            let maxId = res.messages.max(by: { $0.id < $1.id })?.id
            log.debug("getChatHistory chatId=\(job.chatId, privacy: .public) anchorMessageId=\(job.anchorMessageId, privacy: .public) limit=\(job.requestedLimit, privacy: .public) returned=\(res.messages.count, privacy: .public) minId=\(minId ?? 0, privacy: .public) maxId=\(maxId ?? 0, privacy: .public)")
#endif
            for m in res.messages {
#if DEBUG
                debugLogMessageEvent(label: "getChatHistory", chatId: job.chatId, messageId: m.id)
                assert(m.chatId == job.chatId, "TDLib history message chatId mismatch: expected \(job.chatId) got \(m.chatId)")
#endif
                await databaseBatchWriter.enqueue(.upsertMessage(m))
                requestUserIfNeeded(m.senderUserId)
            }

            if job.kind == .older && res.messages.isEmpty {
                reachedHistoryStart.insert(job.chatId)
            }

            historyJobs.removeValue(forKey: res.extra)

            if job.kind == .initialLocal {
                let extra = "history:\(job.chatId):initial:remote:\(UUID().uuidString)"
                historyJobs[extra] = HistoryJob(
                    chatId: job.chatId,
                    kind: .initialRemote,
                    anchorMessageId: 0,
                    requestedLimit: job.requestedLimit,
                    windowLimit: job.windowLimit,
                    onlyLocal: false,
                    generation: job.generation
                )
                sendChatHistory(
                    chatId: job.chatId,
                    fromMessageId: 0,
                    offset: 0,
                    limit: job.requestedLimit,
                    onlyLocal: false,
                    extra: extra
                )
            }

            if selectedChatId == job.chatId {
                let loading = historyJobs.values.contains(where: { $0.chatId == job.chatId })
                await MainActor.run { isLoadingHistory = loading }
            }
        }
    }

#if DEBUG
    private func debugLogMessageEvent(label: String, chatId: Int64, messageId: Int64) {
        log.debug("\(label, privacy: .public) chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
    }
#endif
}
