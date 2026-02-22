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
    @Published private(set) var filteredChats: [TGChat] = []

    private let log = Logger(subsystem: "com.aurora.app", category: "chat.list.vm")
    private let observationQueue = DispatchQueue(label: "com.aurora.app.chat.list.observation", qos: .utility)
    private let publishDebouncer = MainThreadPublishDebouncer<[TGChat]>(delay: 0.033)
    private var cancellables: Set<AnyCancellable> = []
    private let searchQuerySubject = PassthroughSubject<String, Never>()
    private var latestNormalizedSearchQuery: String = ""
    private var lastFilterInput: (query: String, chats: [TGChat])?
    private var applyCount = 0
    private var filterComputeCount = 0

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

        observation
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
                        self.recomputeFilteredChats(source: "chats")
                        AuroraRuntimeMetrics.shared.incrementPublish("chatList")
#if DEBUG
                        if self.applyCount == 1 || self.applyCount % 20 == 0 {
                            self.log.debug("chat list applies=\(self.applyCount, privacy: .public) count=\(self.chats.count, privacy: .public)")
                        }
#endif
                    }
                }
            )
            .store(in: &cancellables)

        searchQuerySubject
            .map(Self.normalizeSearchQuery)
            .removeDuplicates()
            .debounce(for: .milliseconds(140), scheduler: RunLoop.main)
            .sink { [weak self] normalizedQuery in
                guard let self else { return }
                guard self.latestNormalizedSearchQuery != normalizedQuery else { return }
                self.latestNormalizedSearchQuery = normalizedQuery
                self.recomputeFilteredChats(source: "search")
            }
            .store(in: &cancellables)

        recomputeFilteredChats(source: "initial")
    }

    func updateSearchQuery(_ query: String) {
        searchQuerySubject.send(query)
    }

    private func recomputeFilteredChats(source: String) {
        if let lastFilterInput,
           lastFilterInput.query == latestNormalizedSearchQuery,
           lastFilterInput.chats == chats {
            return
        }
        lastFilterInput = (latestNormalizedSearchQuery, chats)

        filterComputeCount += 1
        let nextFilteredChats = Self.filterChats(chats, normalizedQuery: latestNormalizedSearchQuery)
#if DEBUG
        PerfCounters.bumpEvent(
            "ChatListViewModel.filteredChatsComputed",
            details: "source=\(source) computeCount=\(filterComputeCount) chats=\(chats.count) filtered=\(nextFilteredChats.count) queryLen=\(latestNormalizedSearchQuery.count)"
        )
#endif
        guard nextFilteredChats != filteredChats else { return }
        filteredChats = nextFilteredChats
    }

    private static func normalizeSearchQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func filterChats(_ chats: [TGChat], normalizedQuery: String) -> [TGChat] {
        guard !normalizedQuery.isEmpty else { return chats }
        return chats.filter { chat in
            chat.title.lowercased().contains(normalizedQuery)
                || chat.lastMessagePreview.lowercased().contains(normalizedQuery)
        }
    }
}
