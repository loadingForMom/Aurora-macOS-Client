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
    private let publishDebouncer = MainThreadPublishDebouncer<[TGChat]>(delay: 0.033)
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
            .debounce(for: .milliseconds(50), scheduler: observationQueue)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] newChats in
                    guard let self else { return }
                    SwiftUIPublishTrace.storeEvent(
                        name: "snapshot_ready",
                        chatId: nil,
                        details: "source=chatListSnapshot count=\(newChats.count)",
                        reason: "fromDBObserver"
                    )
                    self.publishDebouncer.schedule(
                        value: newChats,
                        chatId: nil,
                        source: "ChatListViewModel.chats"
                    ) { [weak self] snapshot in
                        guard let self else { return }
                        self.applyCount += 1
                        let isViewUpdating = ViewUpdatePhaseTracker.shared.isViewUpdating
                        SwiftUIPublishTrace.publishVM(
                            vm: "ChatListViewModel",
                            property: "chats",
                            chatId: nil,
                            newCount: snapshot.count,
                            reason: "fromDBObserver",
                            isViewUpdating: isViewUpdating
                        )
                        self.chats = snapshot
                        AuroraRuntimeMetrics.shared.incrementPublish("chatList")
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
