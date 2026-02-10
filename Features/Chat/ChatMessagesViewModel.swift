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
    private var coalesceLatestApplyTask: Task<Void, Never>?
    private var pendingLatestSnapshot: [TGMessage]?

    init(store: TelegramStore, chatId: Int64, windowSize: Int = 160) {
        self.store = store
        self.chatId = chatId
        self.windowSize = windowSize
        store.setMessageWindow(chatId: chatId, windowSize: windowSize)
        startStreaming()
    }

    deinit {
        streamTask?.cancel()
        coalesceLatestApplyTask?.cancel()
    }

    private func startStreaming() {
        streamTask?.cancel()
        coalesceLatestApplyTask?.cancel()
        coalesceLatestApplyTask = nil
        pendingLatestSnapshot = nil
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
                let shouldCoalesceLatest = ChatPerfTrace.shouldCoalesceLatest(chatId: chatId)

                await MainActor.run { [weak self] in
                    guard let self else { return }
#if DEBUG
                    self.snapshotReceivedCount += 1
#endif
                    if shouldCoalesceLatest {
                        self.enqueueLatestSnapshot(snapshot, chatId: chatId)
                    } else {
                        self.applySnapshot(snapshot, chatId: chatId)
                    }
                }
            }
        }
    }

    @MainActor
    private func enqueueLatestSnapshot(_ snapshot: [TGMessage], chatId: Int64) {
        pendingLatestSnapshot = snapshot
        guard coalesceLatestApplyTask == nil else { return }

        coalesceLatestApplyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let latest = self.pendingLatestSnapshot else { break }
                self.pendingLatestSnapshot = nil
                self.applySnapshot(latest, chatId: chatId)
                await Task.yield()
            }
            self.coalesceLatestApplyTask = nil
        }
    }

    @MainActor
    private func applySnapshot(_ snapshot: [TGMessage], chatId: Int64) {
        if messages == snapshot {
            if isBootstrapping {
                isBootstrapping = false
            }
            return
        }
        messages = snapshot
        ChatPerfTrace.recordSnapshotApplied(chatId: chatId)
        if isBootstrapping {
            isBootstrapping = false
        }
    }
}
