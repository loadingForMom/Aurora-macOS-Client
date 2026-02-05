//
//  AppDatabaseRepository.swift
//  Aurora
//

import Foundation
import GRDB
import OSLog

struct DatabaseStats: Hashable {
    let chats: Int
    let messages: Int
    let users: Int
}

final class AppDatabaseRepository {
    private let log = Logger(subsystem: "com.aurora.app", category: "db")
    private let dbWriter: DatabaseWriter

    init(dbWriter: DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    func apply(operations: [DatabaseOperation]) {
        guard !operations.isEmpty else { return }
        do {
            try dbWriter.write { db in
                for operation in operations {
                    try apply(operation, in: db)
                }
            }
        } catch {
            log.error("apply batch failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func apply(_ operation: DatabaseOperation, in db: Database) throws {
        switch operation {
        case .upsertChat(let chat):
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
        case .upsertChats(let chats):
            for chat in chats {
                try apply(.upsertChat(chat), in: db)
            }
        case .upsertUser(let user):
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
        case .upsertMessage(let message):
            let (state, errorText) = serializeSendState(message.sendState)
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
        case .upsertMessages(let messages):
            for message in messages {
                try apply(.upsertMessage(message), in: db)
            }
        case .upsertChatLastMessage(let chatId, let messageId, let preview, let date):
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
        case .updateMessageText(let chatId, let messageId, let text):
            try db.execute(
                sql: """
                UPDATE messages
                SET text = ?
                WHERE chat_id = ? AND message_id = ?
                """,
                arguments: [text, chatId, messageId]
            )
        case .updateMessageEdited(let chatId, let messageId, let editDate):
            try db.execute(
                sql: """
                UPDATE messages
                SET edited_at = ?
                WHERE chat_id = ? AND message_id = ?
                """,
                arguments: [editDate, chatId, messageId]
            )
        case .updateChatTitle(let chatId, let title):
            try db.execute(
                sql: "UPDATE chats SET title = ? WHERE chat_id = ?",
                arguments: [title, chatId]
            )
        case .updateChatOrder(let chatId, let order):
            try db.execute(
                sql: "UPDATE chats SET `order` = ? WHERE chat_id = ?",
                arguments: [order, chatId]
            )
        case .updateChatReadInbox(let chatId, let lastReadInboxMessageId, let unreadCount):
            try db.execute(
                sql: """
                UPDATE chats
                SET last_read_inbox_message_id = ?, unread_count = ?
                WHERE chat_id = ?
                """,
                arguments: [lastReadInboxMessageId, unreadCount, chatId]
            )
        case .updateChatLastMessage(let chatId, let messageId, let preview, let date):
            try db.execute(
                sql: """
                UPDATE chats
                SET last_message_id = ?, last_message_preview = ?, last_message_date = ?
                WHERE chat_id = ?
                """,
                arguments: [messageId, preview, date, chatId]
            )
        case .deleteMessages(let chatId, let messageIds):
            guard !messageIds.isEmpty else { return }
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
        case .deleteMessagesByLocalId(let chatId, let localId, let keepingMessageId):
            try db.execute(
                sql: """
                DELETE FROM messages
                WHERE chat_id = ? AND local_id = ? AND message_id != ?
                """,
                arguments: [chatId, localId.uuidString, keepingMessageId]
            )
        }
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
            log.error("upsertChat failed: \(String(describing: error), privacy: .public)")
        }
    }

    func upsertChats(_ chats: [TGChat]) {
        guard !chats.isEmpty else { return }
        do {
            try dbWriter.write { db in
                for chat in chats {
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
            }
        } catch {
            log.error("upsertChats failed: \(String(describing: error), privacy: .public)")
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
            log.error("upsertChatLastMessage failed: \(String(describing: error), privacy: .public)")
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
            log.error("upsertUser failed: \(String(describing: error), privacy: .public)")
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
            log.error("upsertMessage failed: \(String(describing: error), privacy: .public)")
        }
    }

    func upsertMessages(_ messages: [TGMessage]) {
        guard !messages.isEmpty else { return }
        do {
            try dbWriter.write { db in
                for message in messages {
                    let (state, errorText) = serializeSendState(message.sendState)
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
                }
            }
        } catch {
            log.error("upsertMessages failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateMessageText(chatId: Int64, messageId: Int64, text: String) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    UPDATE messages
                    SET text = ?
                    WHERE chat_id = ? AND message_id = ?
                    """,
                    arguments: [text, chatId, messageId]
                )
            }
        } catch {
            log.error("updateMessageText failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateMessageEdited(chatId: Int64, messageId: Int64, editDate: Int) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    UPDATE messages
                    SET edited_at = ?
                    WHERE chat_id = ? AND message_id = ?
                    """,
                    arguments: [editDate, chatId, messageId]
                )
            }
        } catch {
            log.error("updateMessageEdited failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateChatTitle(chatId: Int64, title: String) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE chats SET title = ? WHERE chat_id = ?",
                    arguments: [title, chatId]
                )
            }
        } catch {
            log.error("updateChatTitle failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateChatOrder(chatId: Int64, order: Int64) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: "UPDATE chats SET `order` = ? WHERE chat_id = ?",
                    arguments: [order, chatId]
                )
            }
        } catch {
            log.error("updateChatOrder failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateChatReadInbox(chatId: Int64, lastReadInboxMessageId: Int64, unreadCount: Int32) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    UPDATE chats
                    SET last_read_inbox_message_id = ?, unread_count = ?
                    WHERE chat_id = ?
                    """,
                    arguments: [lastReadInboxMessageId, unreadCount, chatId]
                )
            }
        } catch {
            log.error("updateChatReadInbox failed: \(String(describing: error), privacy: .public)")
        }
    }

    func updateChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int) {
        do {
            try dbWriter.write { db in
                try db.execute(
                    sql: """
                    UPDATE chats
                    SET last_message_id = ?, last_message_preview = ?, last_message_date = ?
                    WHERE chat_id = ?
                    """,
                    arguments: [messageId, preview, date, chatId]
                )
            }
        } catch {
            log.error("updateChatLastMessage failed: \(String(describing: error), privacy: .public)")
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
                    ORDER BY date DESC, message_id DESC
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
                        log.info("fetchLatestMessages dropped \(messages.count - filtered.count) rows for chatId=\(chatId)")
                    }
                }
#endif
#if DEBUG
                assert(filtered.allSatisfy { $0.chatId == chatId }, "DB invariant failed: mismatched chat_id in fetchLatestMessages")
#endif
                return filtered
            }
        } catch {
            log.error("fetchLatestMessages failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func fetchOlderMessages(chatId: Int64, beforeMessageId: Int64, limit: Int) -> [TGMessage] {
        do {
            return try dbWriter.read { db in
                let beforeDate = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT date
                    FROM messages
                    WHERE chat_id = :chatId AND message_id = :before
                    """,
                    arguments: StatementArguments([
                        "chatId": chatId,
                        "before": beforeMessageId
                    ])
                )

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                           send_state, send_state_error, local_id, reply_to_message_id,
                           can_retry, retry_count, next_retry_at, edited_at, sending_id
                    FROM messages
                    WHERE chat_id = :chatId
                    AND (
                        (:beforeDate IS NULL AND message_id < :before)
                        OR (date < :beforeDate)
                        OR (date = :beforeDate AND message_id < :before)
                    )
                    ORDER BY date DESC, message_id DESC
                    LIMIT :limit
                    """,
                    arguments: StatementArguments([
                        "chatId": chatId,
                        "before": beforeMessageId,
                        "beforeDate": beforeDate,
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
                        log.info("fetchOlderMessages dropped \(messages.count - filtered.count) rows for chatId=\(chatId)")
                    }
                }
#endif
#if DEBUG
                assert(filtered.allSatisfy { $0.chatId == chatId }, "DB invariant failed: mismatched chat_id in fetchOlderMessages")
#endif
                return filtered
            }
        } catch {
            log.error("fetchOlderMessages failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func fetchMessage(chatId: Int64, messageId: Int64) -> TGMessage? {
        do {
            return try dbWriter.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                           send_state, send_state_error, local_id, reply_to_message_id,
                           can_retry, retry_count, next_retry_at, edited_at, sending_id
                    FROM messages
                    WHERE chat_id = :chatId AND message_id = :messageId
                    """,
                    arguments: StatementArguments([
                        "chatId": chatId,
                        "messageId": messageId
                    ])
                )
                guard let row else { return nil }
                return mapMessageRow(row)
            }
        } catch {
            log.error("fetchMessage failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func fetchLatestMessage(chatId: Int64) -> TGMessage? {
        do {
            return try dbWriter.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                           send_state, send_state_error, local_id, reply_to_message_id,
                           can_retry, retry_count, next_retry_at, edited_at, sending_id
                    FROM messages
                    WHERE chat_id = :chatId
                    ORDER BY date DESC, message_id DESC
                    LIMIT 1
                    """,
                    arguments: StatementArguments(["chatId": chatId])
                )
                guard let row else { return nil }
                return mapMessageRow(row)
            }
        } catch {
            log.error("fetchLatestMessage failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func hasMessages(chatId: Int64) -> Bool {
        do {
            return try dbWriter.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ? LIMIT 1",
                    arguments: [chatId]
                ) ?? 0
                return count > 0
            }
        } catch {
            log.error("hasMessages failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func messageCount(chatId: Int64) -> Int {
        do {
            return try dbWriter.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE chat_id = ?",
                    arguments: [chatId]
                ) ?? 0
                return count
            }
        } catch {
            log.error("messageCount failed: \(String(describing: error), privacy: .public)")
            return 0
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
            log.error("fetchStats failed: \(String(describing: error), privacy: .public)")
            return DatabaseStats(chats: 0, messages: 0, users: 0)
        }
    }

    func fetchChat(chatId: Int64) -> TGChat? {
        do {
            return try dbWriter.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT chat_id, title, kind, `order`, last_message_preview, last_message_date,
                           unread_count, last_read_inbox_message_id, last_message_id
                    FROM chats
                    WHERE chat_id = ?
                    """,
                    arguments: [chatId]
                )
                guard let row else { return nil }
                return TGChat(row: row)
            }
        } catch {
            log.error("fetchChat failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func fetchUser(userId: Int64) -> TGUser? {
        do {
            return try dbWriter.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT user_id, first_name, last_name, username
                    FROM users
                    WHERE user_id = ?
                    """,
                    arguments: [userId]
                )
                guard let row else { return nil }
                let id: Int64 = row["user_id"]
                let firstName: String = row["first_name"]
                let lastName: String = row["last_name"]
                let username: String = row["username"]
                return TGUser(id: id, firstName: firstName, lastName: lastName, username: username)
            }
        } catch {
            log.error("fetchUser failed: \(String(describing: error), privacy: .public)")
            return nil
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
            log.error("deleteMessages failed: \(String(describing: error), privacy: .public)")
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
            log.error("messageExists failed: \(String(describing: error), privacy: .public)")
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
            log.error("fetchPendingMessages failed: \(String(describing: error), privacy: .public)")
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
