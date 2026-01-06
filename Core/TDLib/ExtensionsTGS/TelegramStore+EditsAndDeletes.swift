//  TelegramStore+EditsAndDeletes.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    struct UpdateMessageEditedParsed {
        let chatId: Int64
        let messageId: Int64
        let editDate: Int
    }

    func parseUpdateMessageEdited(_ upd: String) -> UpdateMessageEditedParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageEdited" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let messageId = (obj["message_id"] as? NSNumber)?.int64Value else { return nil }
        let editDate = (obj["edit_date"] as? NSNumber)?.intValue ?? 0
        return UpdateMessageEditedParsed(chatId: chatId, messageId: messageId, editDate: editDate)
    }

    func applyMessageEdited(chatId: Int64, messageId: Int64, editDate: Int) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }
        var m = arr[idx]
        m.editedAt = editDate
        arr[idx] = m
        messagesByChatId[chatId] = sortChronological(arr)
    }

    struct UpdateMessageContentParsed {
        let chatId: Int64
        let messageId: Int64
        let newContent: [String: Any]
    }

    func parseUpdateMessageContent(_ upd: String) -> UpdateMessageContentParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateMessageContent" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        guard let messageId = (obj["message_id"] as? NSNumber)?.int64Value else { return nil }
        guard let newContent = obj["new_content"] as? [String: Any] else { return nil }
        return UpdateMessageContentParsed(chatId: chatId, messageId: messageId, newContent: newContent)
    }

    func applyMessageContentChanged(chatId: Int64, messageId: Int64, newContent: [String: Any]) {
        guard var arr = messagesByChatId[chatId] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == messageId }) else { return }

        let newText = renderPreviewTextFromContent(newContent)
        let old = arr[idx]

        let updated = TGMessage(
            id: old.id,
            chatId: old.chatId,
            date: old.date,
            isOutgoing: old.isOutgoing,
            senderUserId: old.senderUserId,
            text: newText,
            sendState: old.sendState,
            localId: old.localId,
            sendingId: old.sendingId,
            editedAt: old.editedAt,
            canRetry: old.canRetry
        )

        arr[idx] = updated
        messagesByChatId[chatId] = sortChronological(arr)
        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    struct UpdateDeleteMessagesParsed {
        let chatId: Int64
        let messageIds: [Int64]
    }

    func parseUpdateDeleteMessages(_ upd: String) -> UpdateDeleteMessagesParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateDeleteMessages" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        let ids = (obj["message_ids"] as? [NSNumber])?.map { $0.int64Value } ?? []
        guard !ids.isEmpty else { return nil }
        return UpdateDeleteMessagesParsed(chatId: chatId, messageIds: ids)
    }

    func applyMessagesDeleted(chatId: Int64, messageIds: [Int64]) {
        if var arr = messagesByChatId[chatId], !arr.isEmpty {
            let s = Set(messageIds)
            arr.removeAll { s.contains($0.id) }
            messagesByChatId[chatId] = arr
        }

        for id in messageIds {
            if let localId = localIdByTempMessageId[id] {
                pendingByLocalId.removeValue(forKey: localId)
                localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
                localIdByTempMessageId.removeValue(forKey: id)
            }
        }

        updateChatLastFromLocalTimeline(chatId: chatId)
    }

    func renderPreviewTextFromContent(_ content: [String: Any]) -> String {
        guard let ctype = content["@type"] as? String else { return "(unsupported)" }
        switch ctype {
        case "messageText":
            if let t = content["text"] as? [String: Any],
               let s = t["text"] as? String { return s }
            return ""
        case "messageSticker":
            if let sticker = content["sticker"] as? [String: Any],
               let emoji = sticker["emoji"] as? String { return emoji }
            return "🧩 Sticker"
        case "messagePhoto": return "🖼 Photo"
        case "messageVideo": return "🎬 Video"
        case "messageVoiceNote": return "🎤 Voice"
        case "messageDocument": return "📎 File"
        default:
            return "(\(ctype))"
        }
    }
}
