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
        if let idx = arr.firstIndex(where: { $0.id == msg.id }) {
            arr[idx] = msg
        } else {
            if arr.contains(where: { $0.messageKey == msg.messageKey }) { return }
            arr.append(msg)
        }
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

    // Merge (do not replace) to avoid dropping newer tail/optimistic rows when history windows arrive.
    func mergeMessages(chatId: Int64, incoming: [TGMessage], windowLimit: Int?, reason: String) {
        guard !incoming.isEmpty else { return }

        let existing = messagesByChatId[chatId] ?? []
        let beforeCount = existing.count
        let beforeMax = existing.map(\.id).max() ?? 0

        var byKey: [MessageKey: TGMessage] = [:]
        var keyByLocalId: [UUID: MessageKey] = [:]

        for msg in existing where msg.chatId == chatId {
            let key = msg.messageKey
            byKey[key] = msg
            if let localId = msg.localId {
                keyByLocalId[localId] = key
            }
        }

        func merge(existing: TGMessage, incoming: TGMessage) -> TGMessage {
            var merged = incoming
            if merged.localId == nil { merged.localId = existing.localId }
            if merged.sendingId == nil { merged.sendingId = existing.sendingId }
            return merged
        }

        for var msg in incoming where msg.chatId == chatId {
            if let localId = localIdByTempMessageId[msg.id] ?? serverMessageIdByLocalId.first(where: { $0.value == msg.id })?.key {
                if msg.localId == nil { msg.localId = localId }
                if let existingKey = keyByLocalId[localId], existingKey != msg.messageKey {
                    byKey.removeValue(forKey: existingKey)
                }
            }

            let key = msg.messageKey
            if let existing = byKey[key] {
                byKey[key] = merge(existing: existing, incoming: msg)
            } else {
                byKey[key] = msg
            }
        }

        var merged = Array(byKey.values)
        merged = sortChronological(merged)
        if let windowLimit, merged.count > windowLimit {
            merged.removeFirst(merged.count - windowLimit)
        }
        messagesByChatId[chatId] = merged

#if DEBUG
        if reason.hasPrefix("history") && beforeCount > 0 {
            let existingKeys = Set(existing.map(\.messageKey))
            let mergedKeys = Set(merged.map(\.messageKey))
            assert(!existingKeys.isDisjoint(with: mergedKeys), "[HistoryMerge] chatId=\(chatId) replaced timeline during \(reason)")
        }
        let afterMax = merged.map(\.id).max() ?? 0
        print("[HistoryMerge] chatId=\(chatId) reason=\(reason) count \(beforeCount)->\(merged.count) maxId \(beforeMax)->\(afterMax)")
#endif
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
