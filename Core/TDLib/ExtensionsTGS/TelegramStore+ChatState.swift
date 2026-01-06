//  TelegramStore+ChatState.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func applyChatLastMessageUpdate(chatId: Int64, lastMessageId: Int64, preview: String, date: Int) {
        guard var c = chatsById[chatId] else { return }
        c.lastMessageId = lastMessageId
        c.lastMessagePreview = preview
        c.lastMessageDate = date
        chatsById[chatId] = c
    }

    func applyChatReadInboxUpdate(chatId: Int64, lastReadInboxMessageId: Int64, unreadCount: Int32) {
        guard var c = chatsById[chatId] else { return }
        c.lastReadInboxMessageId = lastReadInboxMessageId
        c.unreadCount = unreadCount
        chatsById[chatId] = c
    }

    func requestUserIfNeeded(_ userId: Int64?) {
        guard let id = userId else { return }
        guard usersById[id] == nil else { return }
        td.send(#"{"@type":"getUser","user_id":\#(id)}"#)
    }
}
