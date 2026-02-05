//
//  ChatMessagesViewModel.swift
//  Aurora
//

import Combine
import Foundation
import GRDB

@MainActor
final class ChatMessagesViewModel: ObservableObject {
    @Published private(set) var messages: [TGMessage] = []

    private let dbPool: DatabasePool
    private let chatId: Int64
    private var windowSize: Int
    private var cancellable: AnyCancellable?

    init(dbPool: DatabasePool, chatId: Int64, windowSize: Int = 160) {
        self.dbPool = dbPool
        self.chatId = chatId
        self.windowSize = windowSize
        startObservation()
    }

    func loadOlder(pageSize: Int = 80, maxWindow: Int = 800) {
        let newSize = min(maxWindow, windowSize + pageSize)
        guard newSize != windowSize else { return }
        windowSize = newSize
        startObservation()
    }

    private func startObservation() {
        cancellable?.cancel()
        let chatId = self.chatId
        let limit = windowSize

        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT chat_id, message_id, date, sender_user_id, is_outgoing, text,
                       send_state, send_state_error, local_id, reply_to_message_id,
                       can_retry, retry_count, next_retry_at, edited_at, sending_id
                FROM messages
                WHERE chat_id = ?
                ORDER BY date DESC, message_id DESC
                LIMIT ?
                """,
                arguments: [chatId, limit]
            )
        }

        cancellable = observation
            .publisher(in: dbPool, scheduling: .async(onQueue: .main))
            .map { rows in rows.map(TGMessage.init(row:)).reversed() }
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] in self?.messages = Array($0) }
            )
    }
}
