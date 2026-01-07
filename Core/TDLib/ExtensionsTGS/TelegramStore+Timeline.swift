//  TelegramStore+Timeline.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func sortChronological(_ arr: [TGMessage]) -> [TGMessage] {
        arr.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    func appendMessage(_ msg: TGMessage, chatId: Int64) {
        var arr = messagesByChatId[chatId] ?? []
        if arr.contains(where: { $0.id == msg.id }) { return }
        arr.append(msg)
        arr = sortChronological(arr)
        if arr.count > 800 { arr.removeFirst(arr.count - 800) }
        messagesByChatId[chatId] = arr
        persistMessage(msg)
    }

    func replaceMessage(chatId: Int64, oldId: Int64, newMessage: TGMessage) {
        var arr = messagesByChatId[chatId] ?? []
        if let idx = arr.firstIndex(where: { $0.id == oldId }) {
            arr[idx] = newMessage
        } else {
            arr.append(newMessage)
        }
        arr = sortChronological(arr)
        if arr.count > 800 { arr.removeFirst(arr.count - 800) }
        messagesByChatId[chatId] = arr
        persistMessage(newMessage)
    }

    func keepOptimisticChatPreviewIfNeeded(chatId: Int64) {
        guard let localLast = messagesByChatId[chatId]?.last else { return }
        guard localLast.isOutgoing else { return }
        if case .sent = localLast.sendState { return }

        guard var c = chatsById[chatId] else { return }

        switch localLast.sendState {
        case .pending:
            c.lastMessagePreview = "You: (sending…) \(localLast.previewText)"
        case .failed:
            c.lastMessagePreview = "You: (failed) \(localLast.previewText)"
        case .sent:
            break
        }

        c.lastMessageDate = localLast.date
        c.lastMessageId = localLast.id
        chatsById[chatId] = c
        persistChat(c)
        persistChatLastMessage(chatId: chatId, messageId: localLast.id, preview: c.lastMessagePreview, date: localLast.date)
    }

    func updateChatLastFromLocalTimeline(chatId: Int64) {
        guard let last = messagesByChatId[chatId]?.last else { return }
        if var c = chatsById[chatId] {
            c.lastMessageId = last.id
            c.lastMessageDate = last.date
            switch last.sendState {
            case .pending:
                c.lastMessagePreview = "You: (sending…) \(last.previewText)"
            case .failed:
                c.lastMessagePreview = "You: (failed) \(last.previewText)"
            case .sent:
                c.lastMessagePreview = last.previewText
            }
            chatsById[chatId] = c
            persistChat(c)
            persistChatLastMessage(chatId: chatId, messageId: last.id, preview: c.lastMessagePreview, date: last.date)
        }
    }
}
