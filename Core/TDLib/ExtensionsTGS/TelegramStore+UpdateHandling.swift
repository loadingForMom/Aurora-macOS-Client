//  TelegramStore+UpdateHandling.swift
//  Aurora
//

import Foundation
import os

extension TelegramStore {

    func handleUpdate(_ upd: String) async {
        if let st = parseAuthState(from: upd) {
            await MainActor.run {
                applyAuthorizationState(st)
            }
            log.info("auth state changed to \(st, privacy: .public)")
        }

        if let update = parseUpdateChatLastMessage(upd) {
            let chatId = update.chatId
            if let order = update.order {
                await databaseBatchWriter.enqueue(.updateChatOrder(chatId: chatId, order: order))
            }

            if let lastMessage = update.lastMessage {
#if DEBUG
                debugLogMessageEvent(label: "updateChatLastMessage", chatId: chatId, messageId: lastMessage.id)
#endif
                _ = await messageStore.mergeMessages(
                    chatId: chatId,
                    messages: [lastMessage],
                    windowLimit: historyWindowLimitByChatId[chatId] ?? 160
                )
                await applyChatLastMessageUpdate(chatId: chatId, lastMessageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
                await databaseBatchWriter.enqueue(
                    [
                        .upsertMessage(lastMessage),
                        .upsertChatLastMessage(chatId: chatId, messageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
                    ]
                )
                await keepOptimisticChatPreviewIfNeeded(chatId: chatId)
            } else if !pendingChatInfoRequests.contains(chatId) {
                pendingChatInfoRequests.insert(chatId)
                td.send(#"{"@type":"getChat","chat_id":\#(chatId)}"#)
            }
        }

        if let (chatId, lastReadInboxMessageId, unreadCount) = parseUpdateChatReadInbox(upd) {
            await applyChatReadInboxUpdate(chatId: chatId, lastReadInboxMessageId: lastReadInboxMessageId, unreadCount: unreadCount)
        }

        let currentAuthState = currentAuthorizationStateSnapshot()

        if currentAuthState == "authorizationStateWaitTdlibParameters", !didSendTdlibParameters {
            if sendTdlibParametersIfPossible() {
                didSendTdlibParameters = true
            }
        }

        if currentAuthState == "authorizationStateReady", !didLoadInitialData {
            didLoadInitialData = true
            td.send(#"{"@type":"getMe","@extra":"getMe"}"#)
            td.send(#"{"@type":"getChats","limit":200}"#)
            td.send(#"{"@type":"loadChats","@extra":"loadChats:main","chat_list":{"@type":"chatListMain"},"limit":200}"#)
        }

        if currentAuthState == "authorizationStateReady", !didRequestInitialStorageStats {
            didRequestInitialStorageStats = true
            await MainActor.run { refreshStorageStatistics() }
        }

        if currentAuthState == "authorizationStateWaitEncryptionKey" {
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
            requestedUserIds.remove(u.id)
            let myPhotoToDownload: Int32? = await MainActor.run {
                userCache[u.id] = u
                guard let meId = myUserId, meId == u.id else { return nil }
                if let p = photoPath {
                    myProfilePhotoPath = p
                }
                if let fid = photoFileId {
                    myPhotoFileId = fid
                    return fid
                }
                return nil
            }
            await databaseBatchWriter.enqueue(.upsertUser(u))

            if let fid = myPhotoToDownload {
                scheduleDownloadFile(fileId: fid, priority: 32, reason: "profile-photo")
            }
        }

        if let (fileId, path) = parseUpdateFilePathIfMyPhoto(upd) {
            markDownloadCompleted(fileId: fileId)
            await MainActor.run {
                guard let target = myPhotoFileId, target == fileId else { return }
                myProfilePhotoPath = path
                _ = myProfileNSImage(pointSize: 36)
            }
        }

        if let (fileId, path) = parseUpdateFilePathIfChatAvatar(upd) {
            markDownloadCompleted(fileId: fileId)
            await MainActor.run {
                guard let chatId = chatIdByAvatarFileId[fileId] else { return }
                applyChatAvatarFileUpdate(chatId: chatId, fileId: fileId, path: path)
            }
        }

        if let update = parseUpdateChatPhoto(upd) {
            await MainActor.run {
                if update.hasPhoto {
                    registerChatAvatar(
                        chatId: update.chatId,
                        smallFileId: update.smallId,
                        bigFileId: update.bigId,
                        initialBestPath: update.bestPath
                    )
                } else {
                    queueChatAvatarPathUpdate(chatId: update.chatId, path: nil)
                    chatAvatarMetaByChatId.removeValue(forKey: update.chatId)
                }
            }
        }

        if let user = parseUserObject(upd) {
            requestedUserIds.remove(user.id)
            await MainActor.run { userCache[user.id] = user }
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
            let firstMessageId = del.messageIds.first ?? 0
            let lastMessageId = del.messageIds.last ?? 0
            log.debug(
                "updateDeleteMessages chatId=\(del.chatId, privacy: .public) ids=\(del.messageIds.count, privacy: .public) first=\(firstMessageId, privacy: .public) last=\(lastMessageId, privacy: .public) from_cache=\(del.fromCache, privacy: .public) is_permanent=\(del.isPermanent, privacy: .public)"
            )
#if DEBUG
            if del.messageIds.count <= 8 {
                del.messageIds.forEach { debugLogMessageEvent(label: "updateDeleteMessages", chatId: del.chatId, messageId: $0) }
            } else {
                let prefixIds = del.messageIds.prefix(3)
                let suffixIds = del.messageIds.suffix(3)
                for id in prefixIds {
                    debugLogMessageEvent(label: "updateDeleteMessages", chatId: del.chatId, messageId: id)
                }
                for id in suffixIds {
                    debugLogMessageEvent(label: "updateDeleteMessages", chatId: del.chatId, messageId: id)
                }
                log.debug(
                    "updateDeleteMessages chatId=\(del.chatId, privacy: .public) omitted_middle_ids=\(del.messageIds.count - 6, privacy: .public)"
                )
            }
#endif
            // TDLib can emit from_cache=true when unloading memory cache; keep persistent rows.
            if del.fromCache {
                return
            }

            await applyMessagesDeleted(chatId: del.chatId, messageIds: del.messageIds)
        }

        // New messages
        if let (chatId, msg) = parseUpdateNewMessage(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateNewMessage", chatId: chatId, messageId: msg.id)
#endif
            if databaseRepository.fetchChat(chatId: chatId) == nil && !pendingChatInfoRequests.contains(chatId) {
                pendingChatInfoRequests.insert(chatId)
                td.send(#"{"@type":"getChat","chat_id":\#(chatId)}"#)
            }

            await requestUserIfNeeded(msg.senderUserId)

            if await tryReconcileOutgoingPendingMessage(msg) {
#if DEBUG
                log.debug("updateNewMessage reconciled -> skip append")
#endif
            } else {
                _ = await messageStore.mergeMessages(
                    chatId: chatId,
                    messages: [msg],
                    windowLimit: historyWindowLimitByChatId[chatId] ?? 160
                )
                await databaseBatchWriter.enqueue(.upsertMessage(msg))
            }

            await updateChatLastFromLocalTimeline(chatId: chatId)
        }
    }

    func handleResponse(_ resp: String) async {
        if let err = parseTdError(resp) {
            if err.extra == "loadChats:main", err.code == 404 {
#if DEBUG
                log.debug("loadChats completed for chatListMain")
#endif
                return
            }
            log.error("tdlib error code=\(err.code, privacy: .public) message=\(err.message, privacy: .public) extra=\(err.extra ?? "nil", privacy: .public)")
            return
        }

        if let obj = parseJSON(resp),
           (obj["@type"] as? String) == "ok",
           (obj["@extra"] as? String) == "loadChats:main" {
            td.send(#"{"@type":"loadChats","@extra":"loadChats:main","chat_list":{"@type":"chatListMain"},"limit":200}"#)
        }

        if let ids = parseChatsResponse(resp) {
            for id in ids {
                td.send(#"{"@type":"getChat","chat_id":\#(id)}"#)
            }
        }

        if let (chat, lastMessage, smallId, bigId, bestPath) = parseChatObject(resp) {
            pendingChatInfoRequests.remove(chat.id)
            await databaseBatchWriter.enqueue(.upsertChat(chat))
            if let lastMessage {
                _ = await messageStore.mergeMessages(
                    chatId: chat.id,
                    messages: [lastMessage],
                    windowLimit: historyWindowLimitByChatId[chat.id] ?? 160
                )
                await databaseBatchWriter.enqueue(
                    [
                        .upsertMessage(lastMessage),
                        .upsertChatLastMessage(chatId: chat.id, messageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
                    ]
                )
            }

            await MainActor.run {
                registerChatAvatar(chatId: chat.id, smallFileId: smallId, bigFileId: bigId, initialBestPath: bestPath)
            }

            let shouldAutoSelect = await MainActor.run { selectedChatId == nil }
            if shouldAutoSelect {
                await MainActor.run {
                    selectedChatId = chat.id
                    AuroraRuntimeMetrics.shared.incrementPublish("storeSelectedChat")
                }
                loadInitialHistory(chatId: chat.id)
            }
        }

        // MARK: - Current user (me) + profile photo

        if let (me, photoFileId, photoPath) = parseMeUserResponse(resp) {
            requestedUserIds.remove(me.id)
            let myPhotoToDownload: Int32? = await MainActor.run {
                myUserId = me.id
                userCache[me.id] = me
                if let p = photoPath {
                    myProfilePhotoPath = p
                }
                if let fid = photoFileId {
                    myPhotoFileId = fid
                    return fid
                }
                return nil
            }
            await databaseBatchWriter.enqueue(.upsertUser(me))
            if let fid = myPhotoToDownload {
                scheduleDownloadFile(fileId: fid, priority: 32, reason: "profile-photo")
            }
        }

        if let user = parseUserObject(resp) {
            requestedUserIds.remove(user.id)
            await MainActor.run { userCache[user.id] = user }
            await databaseBatchWriter.enqueue(.upsertUser(user))
        }

        await MainActor.run {
            if let storage = parseStorageStatisticsAny(resp) {
                applyStorageStatistics(storage)
            }
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
                historyRequestStartedAtNs.removeValue(forKey: res.extra)
                historyMetrics.staleResponses += 1
                syncHistoryLoadingFlagForSelectedChat()
                return
            }

            let latencyMs: Double? = {
                guard let startedAt = historyRequestStartedAtNs.removeValue(forKey: res.extra) else { return nil }
                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                return Double(elapsed) / 1_000_000.0
            }()

            historyMetrics.responses += 1
            if res.messages.isEmpty {
                historyMetrics.emptyResponses += 1
            }
            if let latencyMs {
                historyMetrics.accumulatedLatencyMs += latencyMs
                historyMetrics.maxLatencyMs = max(historyMetrics.maxLatencyMs, latencyMs)
            }

#if DEBUG
            let minId = res.messages.min(by: { $0.id < $1.id })?.id
            let maxId = res.messages.max(by: { $0.id < $1.id })?.id
            log.debug("getChatHistory chatId=\(job.chatId, privacy: .public) anchorMessageId=\(job.anchorMessageId, privacy: .public) limit=\(job.requestedLimit, privacy: .public) returned=\(res.messages.count, privacy: .public) minId=\(minId ?? 0, privacy: .public) maxId=\(maxId ?? 0, privacy: .public) latencyMs=\(latencyMs ?? -1, privacy: .public)")
#endif
#if DEBUG
            if let mismatch = res.messages.first(where: { $0.chatId != job.chatId }) {
                assertionFailure("TDLib history message chatId mismatch: expected \(job.chatId) got \(mismatch.chatId)")
            }
#endif

            let messagesToMerge: [TGMessage]
            if job.kind == .older {
                messagesToMerge = res.messages.filter { $0.id < job.anchorMessageId }
            } else {
                messagesToMerge = res.messages
            }

            if !messagesToMerge.isEmpty {
                _ = await messageStore.mergeMessages(
                    chatId: job.chatId,
                    messages: messagesToMerge,
                    windowLimit: job.windowLimit
                )
                await databaseBatchWriter.enqueue(.upsertMessages(messagesToMerge))
            }

            let senderIds = Set(messagesToMerge.compactMap(\.senderUserId))
            for senderId in senderIds {
                await requestUserIfNeeded(senderId)
            }

            if job.kind == .older {
                if messagesToMerge.isEmpty {
                    reachedHistoryStart.insert(job.chatId)
                    historyMetrics.olderResponsesWithoutOlder += 1
                }
            }

            historyJobs.removeValue(forKey: res.extra)

            if job.kind == .initialLocal {
                let localCount = res.messages.count
                let needMoreByCount = localCount < job.requestedLimit
                let localMaxId = res.messages.map(\.id).max() ?? 0
                let chatLastId = databaseRepository.fetchChat(chatId: job.chatId)?.lastMessageId ?? 0
                let needMoreById = chatLastId > 0 && localMaxId < chatLastId

                if needMoreByCount || needMoreById {
                    requestInitialRemoteHistoryIfNeeded(
                        chatId: job.chatId,
                        generation: job.generation,
                        requestedLimit: job.requestedLimit,
                        windowLimit: job.windowLimit
                    )
                }
            }

#if DEBUG
            let metrics = historyMetrics
            if metrics.responses % 20 == 0 {
                let avgMs = metrics.responses > 0
                    ? (metrics.accumulatedLatencyMs / Double(metrics.responses))
                    : 0
                log.debug(
                    "history metrics localReq=\(metrics.requestsLocal, privacy: .public) remoteReq=\(metrics.requestsRemote, privacy: .public) resp=\(metrics.responses, privacy: .public) stale=\(metrics.staleResponses, privacy: .public) empty=\(metrics.emptyResponses, privacy: .public) noOlder=\(metrics.olderResponsesWithoutOlder, privacy: .public) avgMs=\(avgMs, privacy: .public) maxMs=\(metrics.maxLatencyMs, privacy: .public) maxInFlight=\(metrics.maxInFlightJobs, privacy: .public)"
                )
            }
#endif
            syncHistoryLoadingFlagForSelectedChat()
        }
    }

#if DEBUG
    private func debugLogMessageEvent(label: String, chatId: Int64, messageId: Int64) {
        log.debug("\(label, privacy: .public) chatId=\(chatId, privacy: .public) messageId=\(messageId, privacy: .public)")
    }
#endif
}
