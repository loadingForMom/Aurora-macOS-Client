//  TelegramStore+UpdateHandling.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func handleUpdate(_ upd: String) {
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

        // Response message with @extra
        if let msgResponse = parseMessageFunctionResponse(upd) {
            handleFunctionResponseMessage(msgResponse)
        }

        // Sending lifecycle updates
        if let succ = parseUpdateMessageSendSucceeded(upd) {
            handleSendSucceeded(succ)
        }

        if let fail = parseUpdateMessageSendFailed(upd) {
            handleSendFailed(fail)
        }

        // Edit / content changes
        if let edited = parseUpdateMessageEdited(upd) {
            applyMessageEdited(chatId: edited.chatId, messageId: edited.messageId, editDate: edited.editDate)
        }

        if let content = parseUpdateMessageContent(upd) {
            applyMessageContentChanged(chatId: content.chatId, messageId: content.messageId, newContent: content.newContent)
        }

        // Deletions
        if let del = parseUpdateDeleteMessages(upd) {
            applyMessagesDeleted(chatId: del.chatId, messageIds: del.messageIds)
        }

        // History responses
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

        // New messages
        if let (chatId, msg) = parseUpdateNewMessage(upd) {
            requestUserIfNeeded(msg.senderUserId)

            if tryReconcileOutgoingPendingMessage(msg) {
                // reconciled
            } else {
                appendMessage(msg, chatId: chatId)
            }

            updateChatLastFromLocalTimeline(chatId: chatId)
        }
    }
}

