//
//  ChatMessagesViewModel.swift
//  Aurora
//

import Combine
import Foundation
import GRDB
import OSLog

@MainActor
final class ChatMessagesViewModel: ObservableObject {
    @Published private(set) var messages: [TGMessage] = []

    private let log = Logger(subsystem: "com.aurora.app", category: "chat.messages.vm")
    private let dbPool: DatabasePool
    private let chatId: Int64
    private let observationQueue = DispatchQueue(label: "com.aurora.app.chat.messages.observation", qos: .userInitiated)
    private var windowSize: Int
    private var cancellable: AnyCancellable?
    private var observationGeneration = 0
    private var applyCount = 0

    init(dbPool: DatabasePool, chatId: Int64, windowSize: Int = 160) {
        self.dbPool = dbPool
        self.chatId = chatId
        self.windowSize = windowSize
        startObservation()
    }

    func loadOlder(pageSize: Int = 80, maxWindow: Int = 5_000) {
        let newSize = min(maxWindow, windowSize + pageSize)
        guard newSize != windowSize else { return }
        windowSize = newSize
        startObservation()
    }

    private func startObservation() {
        cancellable?.cancel()
        let chatId = self.chatId
        let limit = windowSize
        observationGeneration += 1
        let generation = observationGeneration
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                       send_state, send_state_error, local_id, reply_to_message_id,
                       can_retry, retry_count, next_retry_at, edited_at, sending_id
                FROM messages
                WHERE chat_id = ?
                ORDER BY (CASE WHEN message_id > 0 THEN message_id ELSE 9000000000000000000 + message_id END) DESC
                LIMIT ?
                """,
                arguments: [chatId, limit]
            )
        }

        cancellable = observation
            .publisher(in: dbPool, scheduling: .async(onQueue: observationQueue))
            .map { rows in rows.map(TGMessage.init(row:)).reversed() }
            .removeDuplicates()
            .debounce(for: .milliseconds(40), scheduler: observationQueue)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] newMessages in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.applyCount += 1
                        self.messages = Array(newMessages)
#if DEBUG
                        if self.applyCount == 1 || self.applyCount % 25 == 0 {
                            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000.0
                            self.log.debug(
                                "messages vm chatId=\(chatId, privacy: .public) gen=\(generation, privacy: .public) applies=\(self.applyCount, privacy: .public) count=\(self.messages.count, privacy: .public) window=\(limit, privacy: .public) sinceStartMs=\(elapsedMs, privacy: .public)"
                            )
                        }
#endif
                    }
                }
            )
    }
}
