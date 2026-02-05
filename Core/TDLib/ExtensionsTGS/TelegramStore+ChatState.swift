//  TelegramStore+ChatState.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func applyChatLastMessageUpdate(chatId: Int64, lastMessageId: Int64, preview: String, date: Int) async {
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
        let needsRequest = await MainActor.run { userCache[id] == nil }
        guard needsRequest else { return }
        td.send(#"{"@type":"getUser","user_id":\#(id)}"#)
    }
}
