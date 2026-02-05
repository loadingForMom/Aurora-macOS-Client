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

    func applyMessageEdited(chatId: Int64, messageId: Int64, editDate: Int) async {
        await databaseBatchWriter.enqueue(.updateMessageEdited(chatId: chatId, messageId: messageId, editDate: editDate))
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

    func applyMessageContentChanged(chatId: Int64, messageId: Int64, newContent: [String: Any]) async {
        let newText = renderPreviewTextFromContent(newContent)
        await updateChatLastFromLocalTimeline(chatId: chatId)
        await databaseBatchWriter.enqueue(.updateMessageText(chatId: chatId, messageId: messageId, text: newText))
    }

    struct UpdateDeleteMessagesParsed {
        let chatId: Int64
        let messageIds: [Int64]
        let fromCache: Bool
        let isPermanent: Bool
    }

    func parseUpdateDeleteMessages(_ upd: String) -> UpdateDeleteMessagesParsed? {
        guard let obj = parseJSON(upd) else { return nil }
        guard (obj["@type"] as? String) == "updateDeleteMessages" else { return nil }
        guard let chatId = (obj["chat_id"] as? NSNumber)?.int64Value else { return nil }
        let ids = (obj["message_ids"] as? [NSNumber])?.map { $0.int64Value } ?? []
        guard !ids.isEmpty else { return nil }
        let fromCache = (obj["from_cache"] as? Bool) ?? ((obj["from_cache"] as? NSNumber)?.boolValue ?? false)
        let isPermanent = (obj["is_permanent"] as? Bool) ?? ((obj["is_permanent"] as? NSNumber)?.boolValue ?? false)
        return UpdateDeleteMessagesParsed(
            chatId: chatId,
            messageIds: ids,
            fromCache: fromCache,
            isPermanent: isPermanent
        )
    }

    func applyMessagesDeleted(chatId: Int64, messageIds: [Int64]) async {
        for id in messageIds {
            if let localId = localIdByTempMessageId[id] {
                if pendingByLocalId[localId] != nil {
                    Task { await finalizePending(localId: localId, result: .canceled) }
                } else {
                    localIdBySendingId = localIdBySendingId.filter { $0.value != localId }
                    localIdByTempMessageId.removeValue(forKey: id)
                }
            }
            if let localId = serverMessageIdByLocalId.first(where: { $0.value == id })?.key {
                serverMessageIdByLocalId.removeValue(forKey: localId)
            }
        }

        await updateChatLastFromLocalTimeline(chatId: chatId)
        await databaseBatchWriter.enqueue(.deleteMessages(chatId: chatId, messageIds: messageIds))
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
