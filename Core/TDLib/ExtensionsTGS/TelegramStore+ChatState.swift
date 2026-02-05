//  TelegramStore+ChatState.swift
//  Aurora
//

import Foundation
import os

extension TelegramStore {

    func applyChatLastMessageUpdate(chatId: Int64, lastMessageId: Int64, preview: String, date: Int) async {
        if let current = databaseRepository.fetchChat(chatId: chatId) {
            if current.lastMessageId > lastMessageId {
                return
            }
            if current.lastMessageId == lastMessageId &&
                current.lastMessagePreview == preview &&
                current.lastMessageDate == date {
                return
            }
        }

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
        let (needsRequest, authorized) = await MainActor.run { (userCache[id] == nil, isAuthorized) }
        guard needsRequest else { return }
        guard authorized else {
            log.info("Blocked TDLib request (not authorized yet): getUser")
            return
        }
        td.send(#"{"@type":"getUser","user_id":\#(id)}"#)
    }
}
