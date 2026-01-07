//
//  AppDatabase.swift
//  Aurora
//

import Foundation
import GRDB

final class AppDatabase {
    let dbWriter: DatabaseQueue

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aurora/app-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("aurora.sqlite")

        dbWriter = try DatabaseQueue(path: dbURL.path)
        try migrator.migrate(dbWriter)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createChats") { db in
            try db.create(table: "chats") { t in
                t.column("chat_id", .integer).notNull().primaryKey()
                t.column("title", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("order", .integer).notNull().defaults(to: 0)
                t.column("last_message_preview", .text).notNull().defaults(to: "")
                t.column("last_message_date", .integer).notNull().defaults(to: 0)
                t.column("unread_count", .integer).notNull().defaults(to: 0)
                t.column("last_read_inbox_message_id", .integer).notNull().defaults(to: 0)
                t.column("last_message_id", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("createUsers") { db in
            try db.create(table: "users") { t in
                t.column("user_id", .integer).notNull().primaryKey()
                t.column("first_name", .text).notNull().defaults(to: "")
                t.column("last_name", .text).notNull().defaults(to: "")
                t.column("username", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("createMessages") { db in
            try db.create(table: "messages") { t in
                t.column("chat_id", .integer).notNull()
                t.column("message_id", .integer).notNull()
                t.column("date", .integer).notNull()
                t.column("sender_user_id", .integer)
                t.column("is_outgoing", .boolean).notNull().defaults(to: false)
                t.column("text", .text).notNull().defaults(to: "")
                t.column("send_state", .text).notNull().defaults(to: "sent")
                t.column("send_state_error", .text)
                t.column("can_retry", .boolean).notNull().defaults(to: false)
                t.column("edited_at", .integer)
                t.column("sending_id", .integer)
                t.primaryKey(["chat_id", "message_id"])
            }
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_messages_chat_id_message_id_desc
            ON messages(chat_id, message_id DESC)
            """)
        }

        migrator.registerMigration("createChatLastMessage") { db in
            try db.create(table: "chat_last_message") { t in
                t.column("chat_id", .integer).notNull().primaryKey()
                t.column("message_id", .integer).notNull()
                t.column("preview", .text).notNull().defaults(to: "")
                t.column("date", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
