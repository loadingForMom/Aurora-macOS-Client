//
//  AppDatabase.swift
//  Aurora
//

import Foundation
import GRDB

final class AppDatabase {
    enum StorageMode {
        case persistent
        case preview
    }

    let dbPool: DatabasePool

    init(storageMode: StorageMode = .persistent) throws {
        let dbURL: URL
        switch storageMode {
        case .persistent:
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Aurora/app-db", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dbURL = dir.appendingPathComponent("aurora.sqlite")
        case .preview:
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AuroraPreviewDB", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dbURL = dir.appendingPathComponent("aurora-preview-\(UUID().uuidString).sqlite")
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(dbPool)
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
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_messages_chat_id_date
            ON messages(chat_id, date)
            """)
        }

        migrator.registerMigration("addMessagePendingMetadata") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "local_id", .text)
                t.add(column: "reply_to_message_id", .integer)
                t.add(column: "retry_count", .integer).notNull().defaults(to: 0)
                t.add(column: "next_retry_at", .integer)
            }
        }

        migrator.registerMigration("createChatLastMessage") { db in
            try db.create(table: "chat_last_message") { t in
                t.column("chat_id", .integer).notNull().primaryKey()
                t.column("message_id", .integer).notNull()
                t.column("preview", .text).notNull().defaults(to: "")
                t.column("date", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("addChatOrderIndex") { db in
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_chats_order
            ON chats(`order`)
            """)
        }

        migrator.registerMigration("createMedia") { db in
            try db.create(table: "media") { t in
                t.column("file_id", .integer).notNull().primaryKey()
                t.column("chat_id", .integer)
                t.column("message_id", .integer)
                t.column("type", .text).notNull()
                t.column("local_path", .text)
                t.column("remote_id", .text)
                t.column("size", .integer)
                t.column("created_at", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_media_chat_message
            ON media(chat_id, message_id)
            """)
        }

        return migrator
    }
}
