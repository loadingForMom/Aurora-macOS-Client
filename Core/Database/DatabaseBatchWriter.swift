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
    private let maxPendingBeforeImmediateFlush: Int

    private var pending: [DatabaseOperation] = []
    private var flushTask: Task<Void, Never>?

    init(
        repository: AppDatabaseRepository,
        coalesceDelay: UInt64 = 30_000_000,
        maxPendingBeforeImmediateFlush: Int = 160
    ) {
        self.repository = repository
        self.coalesceDelay = coalesceDelay
        self.maxPendingBeforeImmediateFlush = max(32, maxPendingBeforeImmediateFlush)
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
        if pending.count >= maxPendingBeforeImmediateFlush {
            flushTask?.cancel()
            flushTask = nil
            flush()
            return
        }

        guard flushTask == nil else { return }
        flushTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.coalesceDelay)
            await self.flush()
        }
    }

    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    private func flush() {
        flushTask = nil
        let operations = pending
        pending.removeAll(keepingCapacity: true)
        guard !operations.isEmpty else { return }
        let compacted = compact(operations)
        repository.apply(operations: compacted)
        if compacted.count == operations.count {
            log.debug("flushed \(compacted.count, privacy: .public) db operations")
        } else {
            log.debug(
                "flushed \(compacted.count, privacy: .public) db operations (from \(operations.count, privacy: .public))"
            )
        }
    }

    private enum CoalesceKey: Hashable {
        case upsertChat(Int64)
        case upsertUser(Int64)
        case upsertMessage(chatId: Int64, messageId: Int64)
        case upsertChatLastMessage(Int64)
        case updateMessageText(chatId: Int64, messageId: Int64)
        case updateMessageEdited(chatId: Int64, messageId: Int64)
        case updateChatTitle(Int64)
        case updateChatOrder(Int64)
        case updateChatReadInbox(Int64)
        case updateChatLastMessage(Int64)
    }

    private struct IndexedOperation {
        let index: Int
        let operation: DatabaseOperation
    }

    private func compact(_ operations: [DatabaseOperation]) -> [DatabaseOperation] {
        var passthrough: [IndexedOperation] = []
        var coalesced: [CoalesceKey: IndexedOperation] = [:]
        var index = 0

        func addLeafOperation(_ operation: DatabaseOperation) {
            defer { index += 1 }

            switch operation {
            case .upsertChat(let chat):
                coalesced[.upsertChat(chat.id)] = IndexedOperation(index: index, operation: operation)

            case .upsertUser(let user):
                coalesced[.upsertUser(user.id)] = IndexedOperation(index: index, operation: operation)

            case .upsertMessage(let message):
                let key = CoalesceKey.upsertMessage(chatId: message.chatId, messageId: message.id)
                coalesced[key] = IndexedOperation(index: index, operation: operation)

            case .upsertChatLastMessage(let chatId, _, _, _):
                coalesced[.upsertChatLastMessage(chatId)] = IndexedOperation(index: index, operation: operation)

            case .updateMessageText(let chatId, let messageId, _):
                let key = CoalesceKey.updateMessageText(chatId: chatId, messageId: messageId)
                coalesced[key] = IndexedOperation(index: index, operation: operation)

            case .updateMessageEdited(let chatId, let messageId, _):
                let key = CoalesceKey.updateMessageEdited(chatId: chatId, messageId: messageId)
                coalesced[key] = IndexedOperation(index: index, operation: operation)

            case .updateChatTitle(let chatId, _):
                coalesced[.updateChatTitle(chatId)] = IndexedOperation(index: index, operation: operation)

            case .updateChatOrder(let chatId, _):
                coalesced[.updateChatOrder(chatId)] = IndexedOperation(index: index, operation: operation)

            case .updateChatReadInbox(let chatId, _, _):
                coalesced[.updateChatReadInbox(chatId)] = IndexedOperation(index: index, operation: operation)

            case .updateChatLastMessage(let chatId, _, _, _):
                coalesced[.updateChatLastMessage(chatId)] = IndexedOperation(index: index, operation: operation)

            case .deleteMessages, .deleteMessagesByLocalId:
                passthrough.append(IndexedOperation(index: index, operation: operation))

            case .upsertChats, .upsertMessages:
                passthrough.append(IndexedOperation(index: index, operation: operation))
            }
        }

        for operation in operations {
            switch operation {
            case .upsertChats(let chats):
                for chat in chats {
                    addLeafOperation(.upsertChat(chat))
                }
            case .upsertMessages(let messages):
                for message in messages {
                    addLeafOperation(.upsertMessage(message))
                }
            default:
                addLeafOperation(operation)
            }
        }

        let merged = passthrough + coalesced.values
        return merged
            .sorted { $0.index < $1.index }
            .map(\.operation)
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
