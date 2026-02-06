//
//  ChatMessagesViewModel.swift
//  Aurora
//

import Foundation
import Combine

@MainActor
final class ChatMessagesViewModel: ObservableObject {
    @Published private(set) var messages: [TGMessage] = []
    @Published private(set) var isBootstrapping: Bool = true

    private let store: TelegramStore
    private let chatId: Int64
    private let windowSize: Int
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

    private func startStreaming() {
        streamTask?.cancel()
        isBootstrapping = true

        let chatId = self.chatId
        let initialWindow = windowSize
        let store = self.store
        let debounceDelayNs: UInt64 = 120_000_000

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            await store.primeMessageStore(chatId: chatId, limit: initialWindow)
            let stream = await store.messageSnapshotStream(chatId: chatId, windowSize: initialWindow)
            var debounceTask: Task<Void, Never>?

            for await snapshot in stream {
                guard !Task.isCancelled else { return }

                debounceTask?.cancel()
                let pending = snapshot
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: debounceDelayNs)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if self.messages == pending {
                            if self.isBootstrapping {
                                self.isBootstrapping = false
                            }
                            return
                        }
                        self.messages = pending
                        if self.isBootstrapping {
                            self.isBootstrapping = false
                        }
                    }
                }
            }

            debounceTask?.cancel()
        }
    }
}
