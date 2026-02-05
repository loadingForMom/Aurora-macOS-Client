//
//  ChatMessagesViewModel.swift
//  Aurora
//

import Foundation
import Combine
import OSLog

@MainActor
final class ChatMessagesViewModel: ObservableObject {
    @Published private(set) var messages: [TGMessage] = []

    private let log = Logger(subsystem: "com.aurora.app", category: "chat.messages.vm")
    private let store: TelegramStore
    private let chatId: Int64
    private var windowSize: Int
    private var applyCount = 0
    private var streamTask: Task<Void, Never>?
    private let publishDebouncer = MainThreadPublishDebouncer<[TGMessage]>(delay: 0.033)

    init(store: TelegramStore, chatId: Int64, windowSize: Int = 160) {
        self.store = store
        self.chatId = chatId
        self.windowSize = windowSize
        store.setMessageWindow(chatId: chatId, windowSize: windowSize)
        startStreaming()
    }

    deinit {
        streamTask?.cancel()
    }

    func loadOlder(pageSize: Int = 80, maxWindow: Int = 5_000) {
        let newSize = min(maxWindow, windowSize + pageSize)
        guard newSize != windowSize else { return }
        windowSize = newSize
        store.setMessageWindow(chatId: chatId, windowSize: windowSize)
    }

    private func startStreaming() {
        streamTask?.cancel()

        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let chatId = self.chatId
        let initialWindow = windowSize
        let store = self.store
        let debouncer = publishDebouncer

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            await store.primeMessageStore(chatId: chatId, limit: initialWindow)
            let stream = await store.messageSnapshotStream(chatId: chatId, windowSize: initialWindow)
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await debouncer.schedule(value: snapshot) { [weak self] debouncedSnapshot in
                    guard let self else { return }
                    self.applyCount += 1
                    self.messages = debouncedSnapshot
                    AuroraRuntimeMetrics.shared.incrementPublish("chatMessages")
#if DEBUG
                    if self.applyCount == 1 || self.applyCount % 25 == 0 {
                        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
                        self.log.debug(
                            "messages vm chatId=\(chatId, privacy: .public) applies=\(self.applyCount, privacy: .public) count=\(self.messages.count, privacy: .public) window=\(self.windowSize, privacy: .public) sinceStartMs=\(elapsedMs, privacy: .public)"
                        )
                    }
#endif
                }
            }
        }
    }
}
