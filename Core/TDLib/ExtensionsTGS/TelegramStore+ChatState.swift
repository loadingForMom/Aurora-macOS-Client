//  TelegramStore+ChatState.swift
//  Aurora
//

import Foundation
import os

extension TelegramStore {

    func applyChatLastMessageUpdate(chatId: Int64, lastMessageId: Int64, preview: String, date: Int) async {
        guard shouldEnqueueChatLastMessageUpdate(
            chatId: chatId,
            messageId: lastMessageId,
            preview: preview,
            date: date
        ) else { return }

        await databaseBatchWriter.enqueue(
            .updateChatLastMessage(chatId: chatId, messageId: lastMessageId, preview: preview, date: date)
        )
    }

    func applyChatReadInboxUpdate(chatId: Int64, lastReadInboxMessageId: Int64, unreadCount: Int32) async {
        await databaseBatchWriter.enqueue(
            .updateChatReadInbox(chatId: chatId, lastReadInboxMessageId: lastReadInboxMessageId, unreadCount: unreadCount)
        )
    }

    func requestUserIfNeeded(_ userId: Int64?) async {
        guard let id = userId else { return }
        if requestedUserIds.contains(id) { return }
        if databaseRepository.fetchUser(userId: id) != nil {
            return
        }
        guard isRequestAuthorizedSnapshot() else {
            log.info("Blocked TDLib request (not authorized yet): getUser")
            return
        }
        requestedUserIds.insert(id)
        enqueueTDLibRequest(
            [
                "@type": "getUser",
                "user_id": id
            ],
            typeOverride: "getUser"
        )
    }
}
