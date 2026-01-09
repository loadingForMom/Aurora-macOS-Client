//
//  AppDatabaseRepository.swift
//  Aurora
//

import Foundation
import GRDB

struct DatabaseStats: Hashable {
    let chats: Int
    let messages: Int
    let users: Int
}

final class AppDatabaseRepository {
    private let dbWriter: DatabaseWriter

    init(dbWriter: DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    func upsertChat(_ chat: TGChat) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO chats (
                        chat_id,
                        title,
                        kind,
                        `order`,
                        last_message_preview,
                        last_message_date,
                        unread_count,
                        last_read_inbox_message_id,
                        last_message_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chat_id) DO UPDATE SET
                        title = excluded.title,
                        kind = excluded.kind,
                        `order` = excluded.`order`,
                        last_message_preview = excluded.last_message_preview,
                        last_message_date = excluded.last_message_date,
                        unread_count = excluded.unread_count,
                        last_read_inbox_message_id = excluded.last_read_inbox_message_id,
                        last_message_id = excluded.last_message_id
                    """,
                    arguments: [
                        chat.id,
                        chat.title,
                        chat.kind.rawValue,
                        chat.order,
                        chat.lastMessagePreview,
                        chat.lastMessageDate,
                        chat.unreadCount,
                        chat.lastReadInboxMessageId,
                        chat.lastMessageId
                    ]
                )
            }
        } catch {
            print("[DB] upsertChat failed: \(error)")
        }
    }

    func upsertChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO chat_last_message (chat_id, message_id, preview, date)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(chat_id) DO UPDATE SET
                        message_id = excluded.message_id,
                        preview = excluded.preview,
                        date = excluded.date
                    """,
                    arguments: [chatId, messageId, preview, date]
                )
            }
        } catch {
            print("[DB] upsertChatLastMessage failed: \(error)")
        }
    }

    func upsertUser(_ user: TGUser) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO users (user_id, first_name, last_name, username)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(user_id) DO UPDATE SET
                        first_name = excluded.first_name,
                        last_name = excluded.last_name,
                        username = excluded.username
                    """,
                    arguments: [user.id, user.firstName, user.lastName, user.username]
                )
            }
        } catch {
            print("[DB] upsertUser failed: \(error)")
        }
    }

    func upsertMessage(_ message: TGMessage) {
        do {
            let (state, errorText) = serializeSendState(message.sendState)
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO messages (
                        chat_id,
                        message_id,
                        date,
                        sender_user_id,
                        is_outgoing,
                        text,
                        send_state,
                        send_state_error,
                        local_id,
                        reply_to_message_id,
                        can_retry,
                        retry_count,
                        next_retry_at,
                        edited_at,
                        sending_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chat_id, message_id) DO UPDATE SET
                        date = excluded.date,
                        sender_user_id = excluded.sender_user_id,
                        is_outgoing = excluded.is_outgoing,
                        text = excluded.text,
                        send_state = excluded.send_state,
                        send_state_error = excluded.send_state_error,
                        local_id = excluded.local_id,
                        reply_to_message_id = excluded.reply_to_message_id,
                        can_retry = excluded.can_retry,
                        retry_count = excluded.retry_count,
                        next_retry_at = excluded.next_retry_at,
                        edited_at = excluded.edited_at,
                        sending_id = excluded.sending_id
                    """,
                    arguments: [
                        message.chatId,
                        message.id,
                        message.date,
                        message.senderUserId,
                        message.isOutgoing,
                        message.text,
                        state,
                        errorText,
                        message.localId?.uuidString,
                        message.replyToMessageId,
                        message.canRetry,
                        message.retryCount,
                        message.nextRetryAt,
                        message.editedAt,
                        message.sendingId
                    ]
                )
#if DEBUG
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ? AND message_id = ?",
                    arguments: [message.chatId, message.id]
                ) ?? 0
                assert(count == 1, "DB invariant failed: duplicate message row for chatId=\(message.chatId) messageId=\(message.id)")
#endif
            }
        } catch {
            print("[DB] upsertMessage failed: \(error)")
        }
    }

    func fetchLatestMessages(chatId: Int64, limit: Int) -> [TGMessage] {
        do {
            return try dbWriter.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                           send_state, send_state_error, local_id, reply_to_message_id,
                           can_retry, retry_count, next_retry_at, edited_at, sending_id
                    FROM messages
                    WHERE chat_id = :chatId
                    ORDER BY message_id DESC
                    LIMIT :limit
                    """,
                    arguments: StatementArguments([
                        "chatId": chatId,
                        "limit": limit
                    ])
                )
                let messages = rows.map(mapMessageRow)
#if DEBUG
                if let bad = messages.first(where: { $0.chatId != chatId }) {
                    assertionFailure("DB returned wrong chatId: expected \(chatId), got \(bad.chatId)")
                }
#endif
                let filtered = messages.filter { $0.chatId == chatId }
#if !DEBUG
                if filtered.count != messages.count {
                    struct LogOnce { static var didLog = false }
                    if !LogOnce.didLog {
                        LogOnce.didLog = true
                        print("[DB] fetchLatestMessages dropped \(messages.count - filtered.count) rows for chatId=\(chatId)")
                    }
                }
#endif
#if DEBUG
                assert(filtered.allSatisfy { $0.chatId == chatId }, "DB invariant failed: mismatched chat_id in fetchLatestMessages")
#endif
                return filtered
            }
        } catch {
            print("[DB] fetchLatestMessages failed: \(error)")
            return []
        }
    }

    func fetchOlderMessages(chatId: Int64, beforeMessageId: Int64, limit: Int) -> [TGMessage] {
        do {
            return try dbWriter.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                           send_state, send_state_error, local_id, reply_to_message_id,
                           can_retry, retry_count, next_retry_at, edited_at, sending_id
                    FROM messages
                    WHERE chat_id = :chatId AND message_id < :before
                    ORDER BY message_id DESC
                    LIMIT :limit
                    """,
                    arguments: StatementArguments([
                        "chatId": chatId,
                        "before": beforeMessageId,
                        "limit": limit
                    ])
                )
                let messages = rows.map(mapMessageRow)
#if DEBUG
                if let bad = messages.first(where: { $0.chatId != chatId }) {
                    assertionFailure("DB returned wrong chatId: expected \(chatId), got \(bad.chatId)")
                }
#endif
                let filtered = messages.filter { $0.chatId == chatId }
#if !DEBUG
                if filtered.count != messages.count {
                    struct LogOnce { static var didLog = false }
                    if !LogOnce.didLog {
                        LogOnce.didLog = true
                        print("[DB] fetchOlderMessages dropped \(messages.count - filtered.count) rows for chatId=\(chatId)")
                    }
                }
#endif
#if DEBUG
                assert(filtered.allSatisfy { $0.chatId == chatId }, "DB invariant failed: mismatched chat_id in fetchOlderMessages")
#endif
                return filtered
            }
        } catch {
            print("[DB] fetchOlderMessages failed: \(error)")
            return []
        }
    }

    func fetchStats() -> DatabaseStats {
        do {
            return try dbWriter.read { db in
                let chatCount = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chats")) ?? 0
                let messageCount = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages")) ?? 0
                let userCount = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users")) ?? 0
                return DatabaseStats(chats: chatCount, messages: messageCount, users: userCount)
            }
        } catch {
            print("[DB] fetchStats failed: \(error)")
            return DatabaseStats(chats: 0, messages: 0, users: 0)
        }
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) {
        guard !messageIds.isEmpty else { return }
        do {
            try dbWriter.write { db in
                let placeholders = Array(repeating: "?", count: messageIds.count).joined(separator: ",")
                var args = StatementArguments()
                args += [chatId]
                for messageId in messageIds {
                    args += [messageId]
                }
                try db.execute(
                    sql: "DELETE FROM messages WHERE chat_id = ? AND message_id IN (\(placeholders))",
                    arguments: args
                )
            }
        } catch {
            print("[DB] deleteMessages failed: \(error)")
        }
    }

    func messageExists(chatId: Int64, messageId: Int64) -> Bool {
        do {
            return try dbWriter.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ? AND message_id = ?",
                    arguments: [chatId, messageId]
                ) ?? 0
                return count > 0
            }
        } catch {
            print("[DB] messageExists failed: \(error)")
            return false
        }
    }

    func fetchPendingMessages() -> [TGMessage] {
        do {
            return try dbWriter.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                           send_state, send_state_error, local_id, reply_to_message_id,
                           can_retry, retry_count, next_retry_at, edited_at, sending_id
                    FROM messages
                    WHERE send_state IN ('pending', 'sending') AND is_outgoing = 1
                    ORDER BY date DESC
                    """
                )
                return rows.map(mapMessageRow)
            }
        } catch {
            print("[DB] fetchPendingMessages failed: \(error)")
            return []
        }
    }

    private func mapMessageRow(_ row: Row) -> TGMessage {
        let chatId: Int64 = row["chat_id"]
        let messageId: Int64 = row["message_id"]
        let date: Int = row["date"]
        let senderUserId: Int64? = row["sender_user_id"]
        let isOutgoing: Bool = row["is_outgoing"]
        let text: String = row["text"]
        let sendState = deserializeSendState(
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

        return TGMessage(
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

    private func serializeSendState(_ state: TGMessageSendState) -> (String, String?) {
        switch state {
        case .sent:
            return ("sent", nil)
        case .pending:
            return ("pending", nil)
        case .sending:
            return ("sending", nil)
        case .failed(let errorText):
            return ("failed", errorText)
        }
    }

    private func deserializeSendState(state: String?, error: String?) -> TGMessageSendState {
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
