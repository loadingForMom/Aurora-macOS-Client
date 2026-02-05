//
//  DatabaseBatchWriter.swift
//  Aurora
//

import Foundation
import OSLog

actor DatabaseBatchWriter {
    private let log = Logger(subsystem: "com.aurora.app", category: "db.batch")
    private let repository: AppDatabaseRepository
    private let coalesceDelay: UInt64

    private var pending: [DatabaseOperation] = []
    private var flushTask: Task<Void, Never>?

    init(repository: AppDatabaseRepository, coalesceDelay: UInt64 = 30_000_000) {
        self.repository = repository
        self.coalesceDelay = coalesceDelay
    }

    func enqueue(_ operation: DatabaseOperation) {
        pending.append(operation)
        scheduleFlush()
    }

    func enqueue(_ operations: [DatabaseOperation]) {
        guard !operations.isEmpty else { return }
        pending.append(contentsOf: operations)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.coalesceDelay)
            await self.flush()
        }
    }

    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    func flush() async {
        flushTask = nil
        let operations = pending
        pending.removeAll(keepingCapacity: true)
        guard !operations.isEmpty else { return }

        await repository.apply(operations: operations)
        log.debug("flushed \(operations.count, privacy: .public) db operations")
    }
}

enum DatabaseOperation {
    case upsertChat(TGChat)
    case upsertChats([TGChat])
    case upsertUser(TGUser)
    case upsertMessage(TGMessage)
    case upsertMessages([TGMessage])
    case upsertChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int)
    case updateMessageText(chatId: Int64, messageId: Int64, text: String)
    case updateMessageEdited(chatId: Int64, messageId: Int64, editDate: Int)
    case updateChatTitle(chatId: Int64, title: String)
    case updateChatOrder(chatId: Int64, order: Int64)
    case updateChatReadInbox(chatId: Int64, lastReadInboxMessageId: Int64, unreadCount: Int32)
    case updateChatLastMessage(chatId: Int64, messageId: Int64, preview: String, date: Int)
    case deleteMessages(chatId: Int64, messageIds: [Int64])
    case deleteMessagesByLocalId(chatId: Int64, localId: UUID, keepingMessageId: Int64)
}
