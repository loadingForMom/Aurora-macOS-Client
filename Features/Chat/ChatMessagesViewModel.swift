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
#if DEBUG
    private(set) var snapshotReceivedCount: Int = 0
#endif

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

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            await store.primeMessageStore(chatId: chatId, limit: initialWindow)
            let stream = await store.messageSnapshotStream(chatId: chatId, windowSize: initialWindow)

            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                ChatPerfTrace.recordSnapshotReceived(chatId: chatId)

                await MainActor.run { [weak self] in
                    guard let self else { return }
#if DEBUG
                    self.snapshotReceivedCount += 1
#endif
                    if self.messages == snapshot {
                        if self.isBootstrapping {
                            self.isBootstrapping = false
                        }
                        return
                    }
                    self.messages = snapshot
                    ChatPerfTrace.recordSnapshotApplied(chatId: chatId)
                    if self.isBootstrapping {
                        self.isBootstrapping = false
                    }
                }
            }
        }
    }
}
