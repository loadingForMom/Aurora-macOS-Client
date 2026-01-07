//  TelegramStore+UpdateHandling.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func handleUpdate(_ upd: String) {
        if let st = parseAuthState(from: upd) {
            let previous = authState
            authState = st

            if st == "authorizationStateClosed" {
                resetSessionState()
            } else if previous == "authorizationStateReady", st != "authorizationStateReady" {
                resetSessionState()
            }
            if let st = parseAuthState(from: upd) {
                print("[AUTH] state =", st)
            }
        }

        if let (chatId, lastMessage) = parseUpdateChatLastMessage(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateChatLastMessage", chatId: chatId, messageId: lastMessage.id)
#endif
            applyChatLastMessageUpdate(chatId: chatId, lastMessageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
            persistMessage(lastMessage)
            persistChatLastMessage(chatId: chatId, messageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
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
        
        if authState == "authorizationStateWaitEncryptionKey" {
            td.send(#"{"@type":"checkDatabaseEncryptionKey","encryption_key":""}"#)
        }

        if let (id, title) = parseUpdateChatTitle(upd) {
            if var c = chatsById[id] {
                c.title = title
                chatsById[id] = c
                persistChat(c)
            }
        }

        if let (chatId, order) = parseUpdateChatPosition(upd) {
            if var c = chatsById[chatId] {
                c.order = order
                chatsById[chatId] = c
                persistChat(c)
            }
        }

        if let (u, photoFileId, photoPath) = parseUpdateUser(upt: upd) {
            usersById[u.id] = u
            persistUser(u)

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
            persistUser(user)
        }

        // Sending lifecycle updates
        if let succ = parseUpdateMessageSendSucceeded(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageSendSucceeded", chatId: succ.message.chatId, messageId: succ.message.id)
#endif
            handleSendSucceeded(succ)
        }

        if let fail = parseUpdateMessageSendFailed(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageSendFailed", chatId: fail.message.chatId, messageId: fail.message.id)
#endif
            handleSendFailed(fail)
        }

        // Edit / content changes
        if let edited = parseUpdateMessageEdited(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageEdited", chatId: edited.chatId, messageId: edited.messageId)
#endif
            applyMessageEdited(chatId: edited.chatId, messageId: edited.messageId, editDate: edited.editDate)
        }

        if let content = parseUpdateMessageContent(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateMessageContent", chatId: content.chatId, messageId: content.messageId)
#endif
            applyMessageContentChanged(chatId: content.chatId, messageId: content.messageId, newContent: content.newContent)
        }

        // Deletions
        if let del = parseUpdateDeleteMessages(upd) {
#if DEBUG
            del.messageIds.forEach { debugLogMessageEvent(label: "updateDeleteMessages", chatId: del.chatId, messageId: $0) }
#endif
            applyMessagesDeleted(chatId: del.chatId, messageIds: del.messageIds)
        }

        // New messages
        if let (chatId, msg) = parseUpdateNewMessage(upd) {
#if DEBUG
            debugLogMessageEvent(label: "updateNewMessage", chatId: chatId, messageId: msg.id)
#endif
            requestUserIfNeeded(msg.senderUserId)

            if tryReconcileOutgoingPendingMessage(msg) {
                // reconciled
            } else {
                appendMessage(msg, chatId: chatId)
            }

            updateChatLastFromLocalTimeline(chatId: chatId)
        }
    }

    func handleResponse(_ resp: String) {
        if let ids = parseChatsResponse(resp) {
            for id in ids {
                td.send(#"{"@type":"getChat","chat_id":\#(id)}"#)
            }
        }

        if let (chat, lastMessage, smallId, bigId, bestPath) = parseChatObject(resp) {
            chatsById[chat.id] = chat
            persistChat(chat)
            if let lastMessage {
                persistMessage(lastMessage)
                persistChatLastMessage(chatId: chat.id, messageId: lastMessage.id, preview: lastMessage.previewText, date: lastMessage.date)
            }

            if let p = bestPath {
                chatAvatarPathByChatId[chat.id] = p
            }

            registerChatAvatar(chatId: chat.id, smallFileId: smallId, bigFileId: bigId, initialBestPath: bestPath)

            if selectedChatId == nil {
                selectedChatId = chat.id
                loadLatestHistory(chatId: chat.id)
            }
        }

        // MARK: - Current user (me) + profile photo

        if let (me, photoFileId, photoPath) = parseMeUserResponse(resp) {
            myUserId = me.id
            usersById[me.id] = me
            persistUser(me)

            if let p = photoPath {
                myProfilePhotoPath = p
            }

            if let fid = photoFileId {
                myPhotoFileId = fid
                downloadMyPhotoIfNeeded(fileId: fid)
            }
        }

        if let user = parseUserObject(resp) {
            usersById[user.id] = user
            persistUser(user)
        }

        if let storage = parseStorageStatisticsAny(resp) {
            applyStorageStatistics(storage)
        }

        // Response message with @extra
        if let msgResponse = parseMessageFunctionResponse(resp) {
            handleFunctionResponseMessage(msgResponse)
        }

        // History responses
        if let res = parseMessagesResponse(resp), var job = historyJobs[res.extra] {
            for m in res.messages {
#if DEBUG
                debugLogMessageEvent(label: "getChatHistory", chatId: job.chatId, messageId: m.id)
                assert(m.chatId == job.chatId, "TDLib history message chatId mismatch: expected \(job.chatId) got \(m.chatId)")
#endif
                job.accById[m.id] = m
                persistMessage(m)
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
    }

#if DEBUG
    private func debugLogMessageEvent(label: String, chatId: Int64, messageId: Int64) {
        print("[TDLib] \(label) chatId=\(chatId) messageId=\(messageId)")
    }
#endif
}
