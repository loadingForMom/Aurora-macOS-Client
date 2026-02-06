//
//  TGRecordMapping.swift
//  Aurora
//

import Foundation
import GRDB

extension TGChat {
    nonisolated init(row: Row) {
        let id: Int64 = row["chat_id"]
        let title: String = row["title"]
        let kindRaw: String = row["kind"]
        let order: Int64 = row["order"]
        let lastMessagePreview: String = row["last_message_preview"]
        let lastMessageDate: Int = row["last_message_date"]
        let unreadCount: Int32 = row["unread_count"]
        let lastReadInboxMessageId: Int64 = row["last_read_inbox_message_id"]
        let lastMessageId: Int64 = row["last_message_id"]
        self.init(
            id: id,
            title: title,
            kind: TGChatKind(rawValue: kindRaw) ?? .unknown,
            order: order,
            lastMessagePreview: lastMessagePreview,
            lastMessageDate: lastMessageDate,
            unreadCount: unreadCount,
            lastReadInboxMessageId: lastReadInboxMessageId,
            lastMessageId: lastMessageId
        )
    }
}

extension TGMessage {
    nonisolated init(row: Row) {
        let chatId: Int64 = row["chat_id"]
        let messageId: Int64 = row["message_id"]
        let date: Int = row["date"]
        let senderUserId: Int64? = row["sender_user_id"]
        let isOutgoing: Bool = row["is_outgoing"]
        let text: String = row["text"]
        let sendState = TGMessage.deserializeSendState(
            state: row["send_state"],
            error: row["send_state_error"]
        )
        let localIdString: String? = row["local_id"]
        let replyToMessageId: Int64? = row["reply_to_message_id"]
        let canRetry: Bool = row["can_retry"]
        let retryCount: Int = row["retry_count"]
        let nextRetryAt: Int? = row["next_retry_at"]
        let editedAt: Int? = row["edited_at"]
        let sendingId: Int32? = row["sending_id"]

        self.init(
            id: messageId,
            chatId: chatId,
            date: date,
            isOutgoing: isOutgoing,
            senderUserId: senderUserId,
            text: text,
            contentType: "messageText",
            rawText: text,
            entities: [],
            sendState: sendState,
            replyToMessageId: replyToMessageId,
            localId: localIdString.flatMap(UUID.init(uuidString:)),
            sendingId: sendingId,
            editedAt: editedAt,
            canRetry: canRetry,
            retryCount: retryCount,
            nextRetryAt: nextRetryAt
        )
    }
}

extension TGMessage {
    nonisolated static func deserializeSendState(state: String?, error: String?) -> TGMessageSendState {
        switch state {
        case "pending":
            return .pending
        case "sending":
            return .sending
        case "failed":
            return .failed(errorText: error ?? "Failed to send")
        default:
            return .sent
        }
    }
}
