//
//  ChatListViewModel.swift
//  Aurora
//

import Combine
import Foundation
import GRDB

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published private(set) var chats: [TGChat] = []

    private var cancellable: AnyCancellable?

    init(dbPool: DatabasePool) {
        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT chat_id, title, kind, `order`, last_message_preview, last_message_date,
                       unread_count, last_read_inbox_message_id, last_message_id
                FROM chats
                ORDER BY `order` DESC, last_message_date DESC, title COLLATE NOCASE
                """
            )
        }

        cancellable = observation
            .publisher(in: dbPool, scheduling: .async(onQueue: .main))
            .map { rows in rows.map(TGChat.init(row:)) }
            .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] in self?.chats = $0 }
            )
    }
}
