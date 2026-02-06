//
//  ChatMessagesViewModel.swift
//  Aurora
//

import Foundation
import Combine

@MainActor
final class ChatMessagesViewModel: ObservableObject {
    @Published private(set) var messages: [TGMessage] = []

    private let store: TelegramStore
    private let chatId: Int64
    private var windowSize: Int
    private var lastPublishedCount: Int = 0
    private var lastPublishedLastId: Int64?
    private var streamTask: Task<Void, Never>?

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

        let chatId = self.chatId
        let initialWindow = windowSize
        let store = self.store
        let debounceDelayNs: UInt64 = 120_000_000

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            await store.primeMessageStore(chatId: chatId, limit: initialWindow)
            let stream = await store.messageSnapshotStream(chatId: chatId, windowSize: initialWindow)
            var lastStreamCount: Int?
            var lastStreamLastId: Int64?
            var debounceTask: Task<Void, Never>?

            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                let streamCount = snapshot.count
                let streamLastId = snapshot.last?.id
                if lastStreamCount == streamCount && lastStreamLastId == streamLastId {
                    continue
                }
                lastStreamCount = streamCount
                lastStreamLastId = streamLastId

                debounceTask?.cancel()
                let pending = snapshot
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: debounceDelayNs)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let publishCount = pending.count
                        let publishLastId = pending.last?.id
                        if self.lastPublishedCount == publishCount && self.lastPublishedLastId == publishLastId {
                            return
                        }
                        self.lastPublishedCount = publishCount
                        self.lastPublishedLastId = publishLastId
                        self.messages = pending
                    }
                }
            }

            debounceTask?.cancel()
        }
    }
}
