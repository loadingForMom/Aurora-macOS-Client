//
//  ChatListViewModel.swift
//  Aurora
//

import Combine
import Foundation
import GRDB
import OSLog

@MainActor
final class ChatListViewModel: ObservableObject {
    @Published private(set) var chats: [TGChat] = []

    private let log = Logger(subsystem: "com.aurora.app", category: "chat.list.vm")
    private let observationQueue = DispatchQueue(label: "com.aurora.app.chat.list.observation", qos: .utility)
    private var cancellable: AnyCancellable?
    private var applyCount = 0

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
            .publisher(in: dbPool, scheduling: .async(onQueue: observationQueue))
            .map { rows in rows.map(TGChat.init(row:)) }
            .removeDuplicates()
            .debounce(for: .milliseconds(40), scheduler: observationQueue)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] newChats in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.applyCount += 1
                        self.chats = newChats
#if DEBUG
                        if self.applyCount == 1 || self.applyCount % 20 == 0 {
                            self.log.debug("chat list applies=\(self.applyCount, privacy: .public) count=\(self.chats.count, privacy: .public)")
                        }
#endif
                    }
                }
            )
    }
}
