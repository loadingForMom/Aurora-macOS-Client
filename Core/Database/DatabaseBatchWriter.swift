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
    private let burstCoalesceDelay: UInt64
    private let burstImmediateFlushThreshold: Int
    private let burstBatchLimit: Int
    private let burstWindowNs: UInt64
    private let burstOpsThreshold: Int

    private var pending: [DatabaseOperation] = []
    private var flushTask: Task<Void, Never>?
    private var scheduledFlushDelay: UInt64?
    private var recentEnqueueSamples: [(timestamp: UInt64, count: Int)] = []

    init(
        repository: AppDatabaseRepository,
        coalesceDelay: UInt64 = 30_000_000,
        maxPendingBeforeImmediateFlush: Int = 160
    ) {
        let normalizedMaxPending = max(32, maxPendingBeforeImmediateFlush)
        self.repository = repository
        self.coalesceDelay = coalesceDelay
        self.maxPendingBeforeImmediateFlush = normalizedMaxPending
        self.burstCoalesceDelay = min(coalesceDelay, 8_000_000)
        self.burstImmediateFlushThreshold = max(48, normalizedMaxPending * 3 / 4)
        self.burstBatchLimit = max(48, normalizedMaxPending * 3 / 5)
        self.burstWindowNs = 600_000_000
        self.burstOpsThreshold = max(80, normalizedMaxPending * 3 / 4)
    }

    func enqueue(_ operation: DatabaseOperation) {
        pending.append(operation)
        recordEnqueue(count: 1)
        scheduleFlush()
    }

    func enqueue(_ operations: [DatabaseOperation]) {
        guard !operations.isEmpty else { return }
        pending.append(contentsOf: operations)
        recordEnqueue(count: operations.count)
        scheduleFlush()
    }

    private func scheduleFlush() {
        let now = DispatchTime.now().uptimeNanoseconds
        let burstMode = isBurstMode(now: now)
        let immediateThreshold = burstMode
            ? burstImmediateFlushThreshold
            : maxPendingBeforeImmediateFlush
        if pending.count >= immediateThreshold {
            flushTask?.cancel()
            flushTask = nil
            scheduledFlushDelay = nil
            flush()
            return
        }

        let desiredDelay = burstMode ? burstCoalesceDelay : coalesceDelay
        if flushTask != nil {
            let currentDelay = scheduledFlushDelay ?? UInt64.max
            guard desiredDelay < currentDelay else { return }
            flushTask?.cancel()
            flushTask = nil
            scheduledFlushDelay = nil
        }
        scheduleFlushTask(after: desiredDelay)
    }

    private func scheduleFlushTask(after delay: UInt64) {
        guard flushTask == nil else { return }
        scheduledFlushDelay = delay
        flushTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            await self.flush()
        }
    }

    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        scheduledFlushDelay = nil
        flush(drainAll: true)
    }

    private func flush(drainAll: Bool = false) {
        flushTask = nil
        scheduledFlushDelay = nil

        while true {
            let operations = pending
            pending.removeAll(keepingCapacity: true)
            guard !operations.isEmpty else { return }

            let now = DispatchTime.now().uptimeNanoseconds
            let burstMode = isBurstMode(now: now)
            let compacted = compact(operations)
            guard !compacted.isEmpty else {
                if drainAll {
                    continue
                }
                if !pending.isEmpty {
                    scheduleFlushTask(after: burstMode ? burstCoalesceDelay : coalesceDelay)
                }
                return
            }

            let batchLimit: Int = {
                if drainAll {
                    return compacted.count
                }
                if burstMode && compacted.count > burstBatchLimit {
                    return burstBatchLimit
                }
                return compacted.count
            }()

            let applied = Array(compacted.prefix(batchLimit))
            let deferredCount = compacted.count - applied.count
            if deferredCount > 0 {
                pending.insert(contentsOf: compacted.suffix(deferredCount), at: 0)
            }

            repository.apply(operations: applied)
            if deferredCount > 0 {
                log.debug(
                    "flushed \(applied.count, privacy: .public) db operations (from \(operations.count, privacy: .public), deferred \(deferredCount, privacy: .public)) mode=\(burstMode ? "burst" : "normal", privacy: .public)"
                )
            } else if applied.count == operations.count {
                log.debug("flushed \(applied.count, privacy: .public) db operations mode=\(burstMode ? "burst" : "normal", privacy: .public)")
            } else {
                log.debug(
                    "flushed \(applied.count, privacy: .public) db operations (from \(operations.count, privacy: .public)) mode=\(burstMode ? "burst" : "normal", privacy: .public)"
                )
            }

            if drainAll {
                continue
            }

            if !pending.isEmpty {
                scheduleFlushTask(after: burstMode ? burstCoalesceDelay : coalesceDelay)
            }
            return
        }
    }

    private func recordEnqueue(count: Int) {
        guard count > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        recentEnqueueSamples.append((timestamp: now, count: count))
        trimRecentEnqueueSamples(now: now)
    }

    private func isBurstMode(now: UInt64) -> Bool {
        trimRecentEnqueueSamples(now: now)
        let recentOps = recentEnqueueSamples.reduce(into: 0) { partialResult, sample in
            partialResult += sample.count
        }
        return recentOps >= burstOpsThreshold
    }

    private func trimRecentEnqueueSamples(now: UInt64) {
        let minTimestamp = now > burstWindowNs ? (now - burstWindowNs) : 0
        while let first = recentEnqueueSamples.first, first.timestamp < minTimestamp {
            recentEnqueueSamples.removeFirst()
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
