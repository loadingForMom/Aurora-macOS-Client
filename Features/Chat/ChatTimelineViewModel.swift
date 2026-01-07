//
//  ChatTimelineViewModel.swift
//  Aurora
//
//  Virtualized chat timeline coordinator. Owns windowing, pagination,
//  scroll state, and performance logging. Heavy parsing/layout is delegated
//  to MessageTextRenderer off the main thread.
//

import SwiftUI
import Combine
import AppKit
import os

@MainActor
final class ChatTimelineViewModel: ObservableObject {
    struct Metrics: Equatable {
        var initialRenderSeconds: Double?
        var messageCount: Int = 0
        var windowCount: Int = 0
    }

    struct WindowUpdate {
        let items: [ChatMessageItem]
        let reloadIds: Set<Int64>
        let animated: Bool
        let scrollCommand: ScrollCommand?
    }

    enum ScrollCommand: Equatable {
        case toBottom(animated: Bool)
        case toMessage(id: Int64, position: NSCollectionView.ScrollPosition)
    }

    @Published private(set) var newIncomingCount: Int = 0
    @Published private(set) var isAtBottom: Bool = true
    @Published private(set) var metrics: Metrics = Metrics()

    let renderer: MessageTextRenderer

    let store: TelegramStore
    private(set) var chat: TGChat

    private var messages: [TGMessage] = []
    private var windowRange: Range<Int> = 0..<0
    private var windowMessages: [TGMessage] = []
    private var windowMessageIds: [Int64] = []

    private let initialWindowSize = 120
    private let maxWindowSize = 360
    private let pageSize = 100

    private var pendingAnchorId: Int64? = nil
    private var isPagingInFlight: Bool = false
    private var didInitialScroll: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    private let log = Logger(subsystem: "Aurora.Chat", category: "Timeline")
    private let signposter = OSSignposter(subsystem: "Aurora.Chat", category: "Timeline")
    private var openSignpostState: OSSignpostIntervalState?
    private var openStartedAt: Date?

    private static var scrollMemory: [Int64: Int64] = [:]

    var onWindowUpdate: ((WindowUpdate) -> Void)?
    private var pendingWindowUpdate: WindowUpdate?

    init(store: TelegramStore, chat: TGChat, renderer: MessageTextRenderer) {
        self.store = store
        self.chat = chat
        self.renderer = renderer
        subscribeToStore()
        startOpenSignpost()
        applyStressModeIfNeeded()
    }

    func updateChat(_ chat: TGChat) {
        guard self.chat.id != chat.id else { return }
        saveScrollPosition()
        self.chat = chat
        resetState()
        subscribeToStore()
        startOpenSignpost()
        applyStressModeIfNeeded()
    }

    func emitCurrentWindow() {
        if let update = pendingWindowUpdate {
            onWindowUpdate?(update)
        }
    }

    func message(at index: Int) -> TGMessage? {
        guard index >= 0, index < windowMessages.count else { return nil }
        return windowMessages[index]
    }

    func messageById(_ id: Int64) -> TGMessage? {
        guard let idx = windowMessageIds.firstIndex(of: id) else { return nil }
        return windowMessages[idx]
    }

    func scrollToBottom() {
        onWindowUpdate?(WindowUpdate(items: windowItems(), reloadIds: [], animated: true, scrollCommand: .toBottom(animated: true)))
    }

    func handleScroll(firstVisibleIndex: Int?, lastVisibleIndex: Int?, isAtBottom: Bool) {
        self.isAtBottom = isAtBottom
        if isAtBottom && newIncomingCount != 0 {
            newIncomingCount = 0
        }

        if let firstVisibleIndex {
            if let id = message(at: firstVisibleIndex)?.id {
                Self.scrollMemory[chat.id] = id
            }

            if shouldPageOlder(firstVisibleIndex: firstVisibleIndex) {
                requestOlderHistory(anchorId: message(at: firstVisibleIndex)?.id)
            }
        }

        if let lastVisibleIndex {
            markVisibleRead(startIndex: firstVisibleIndex ?? 0, endIndex: lastVisibleIndex)
        }
    }

    func prefetch(indices: [Int]) {
        guard !windowMessages.isEmpty else { return }
        for index in indices {
            guard let message = message(at: index) else { continue }
            let style = MessageTextStyle(fontSize: 14, isOutgoing: message.isOutgoing)
            renderer.prefetch(message: message, style: style)
        }
    }

    private func subscribeToStore() {
        cancellables.removeAll()
        store.$messagesByChatId
            .map { $0[self.chat.id] ?? [] }
            .receive(on: RunLoop.main)
            .sink { [weak self] incoming in
                self?.handleMessagesUpdate(incoming)
            }
            .store(in: &cancellables)
    }

    private func handleMessagesUpdate(_ incoming: [TGMessage]) {
        let previousMessages = messages
        messages = incoming
        metrics.messageCount = incoming.count

        guard !incoming.isEmpty else {
            windowRange = 0..<0
            windowMessages = []
            windowMessageIds = []
            metrics.windowCount = 0
            let update = WindowUpdate(items: [], reloadIds: [], animated: false, scrollCommand: nil)
            pendingWindowUpdate = update
            onWindowUpdate?(update)
            return
        }

        if previousMessages.isEmpty {
            let window = initialWindow(for: incoming)
            applyWindow(window, animated: false, scrollCommand: initialScrollCommand())
            return
        }

        let reloadIds = updatedMessageIds(previous: previousMessages, current: incoming)

        if let scrollCommand = handlePaginationIfNeeded(previous: previousMessages, current: incoming) {
            applyWindow(windowRange, animated: false, scrollCommand: scrollCommand, reloadIds: reloadIds)
            return
        }

        if let appendCommand = handleAppendedMessages(previous: previousMessages, current: incoming) {
            applyWindow(windowRange, animated: true, scrollCommand: appendCommand, reloadIds: reloadIds)
            return
        }

        if reloadIds.isEmpty {
            return
        }

        applyWindow(windowRange, animated: false, scrollCommand: nil, reloadIds: reloadIds)
    }

    private func initialWindow(for messages: [TGMessage]) -> Range<Int> {
        let end = messages.count
        let start = max(0, end - initialWindowSize)
        return start..<end
    }

    private func initialScrollCommand() -> ScrollCommand? {
        if let anchor = Self.scrollMemory[chat.id] {
            return .toMessage(id: anchor, position: .top)
        }
        return .toBottom(animated: false)
    }

    private func applyWindow(_ range: Range<Int>, animated: Bool, scrollCommand: ScrollCommand?, reloadIds: Set<Int64> = []) {
        let clamped = range.lowerBound < 0 ? 0..<range.upperBound : range
        let upper = min(clamped.upperBound, messages.count)
        let lower = max(0, min(clamped.lowerBound, upper))
        windowRange = lower..<upper
        windowMessages = Array(messages[windowRange])
        windowMessageIds = windowMessages.map { $0.id }
        metrics.windowCount = windowMessages.count

        if !didInitialScroll {
            didInitialScroll = true
            stopOpenSignpost()
        }

        let update = WindowUpdate(items: windowItems(), reloadIds: reloadIds, animated: animated, scrollCommand: scrollCommand)
        pendingWindowUpdate = update
        onWindowUpdate?(update)
    }

    private func windowItems() -> [ChatMessageItem] {
        windowMessageIds.map { ChatMessageItem(id: $0) }
    }

    private func updatedMessageIds(previous: [TGMessage], current: [TGMessage]) -> Set<Int64> {
        guard !windowMessageIds.isEmpty else { return [] }
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var updated: Set<Int64> = []
        for message in windowMessages {
            guard let newMessage = currentById[message.id] else { continue }
            if newMessage != message {
                updated.insert(message.id)
            }
        }
        return updated
    }

    private func handlePaginationIfNeeded(previous: [TGMessage], current: [TGMessage]) -> ScrollCommand? {
        guard isPagingInFlight, let anchorId = pendingAnchorId else { return nil }
        isPagingInFlight = false
        pendingAnchorId = nil

        guard let anchorIndex = current.firstIndex(where: { $0.id == anchorId }) else { return nil }
        let newStart = max(0, anchorIndex - pageSize)
        let newEnd = min(current.count, newStart + maxWindowSize)
        windowRange = newStart..<newEnd
        return .toMessage(id: anchorId, position: .top)
    }

    private func handleAppendedMessages(previous: [TGMessage], current: [TGMessage]) -> ScrollCommand? {
        guard current.count >= previous.count else { return nil }
        let delta = current.count - previous.count
        guard delta > 0 else { return nil }

        let appended = current.suffix(delta)
        let lastIsOutgoing = appended.last?.isOutgoing ?? false
        if isAtBottom || lastIsOutgoing {
            let end = current.count
            let start = max(0, end - maxWindowSize)
            windowRange = start..<end
            newIncomingCount = 0
            return .toBottom(animated: true)
        }

        newIncomingCount += delta
        return nil
    }

    private func shouldPageOlder(firstVisibleIndex: Int) -> Bool {
        guard !isPagingInFlight else { return false }
        guard firstVisibleIndex <= 6 else { return false }
        return true
    }

    private func requestOlderHistory(anchorId: Int64?) {
        guard !isPagingInFlight else { return }
        guard let anchorId else { return }
        guard !store.isLoadingHistory else { return }

        pendingAnchorId = anchorId
        isPagingInFlight = true
        store.loadMoreHistory(chatId: chat.id)
    }

    private func markVisibleRead(startIndex: Int, endIndex: Int) {
        guard !windowMessages.isEmpty else { return }
        let clampedStart = max(0, min(startIndex, windowMessages.count - 1))
        let clampedEnd = max(0, min(endIndex, windowMessages.count - 1))
        guard clampedEnd >= clampedStart else { return }

        let ids = windowMessages[clampedStart...clampedEnd]
            .filter { !$0.isOutgoing }
            .map { $0.id }
        guard !ids.isEmpty else { return }
        store.viewMessages(chatId: chat.id, messageIds: ids, forceRead: false)
    }

    private func resetState() {
        messages = []
        windowRange = 0..<0
        windowMessages = []
        windowMessageIds = []
        newIncomingCount = 0
        isAtBottom = true
        isPagingInFlight = false
        pendingAnchorId = nil
        didInitialScroll = false
        metrics = Metrics()
    }

    private func saveScrollPosition() {
        if let id = windowMessageIds.first {
            Self.scrollMemory[chat.id] = id
        }
    }

    private func startOpenSignpost() {
        openSignpostState = signposter.beginInterval("ChatOpen")
        openStartedAt = Date()
    }

    private func stopOpenSignpost() {
        guard let state = openSignpostState else { return }
        signposter.endInterval("ChatOpen", state)
        openSignpostState = nil
        if let start = openStartedAt {
            metrics.initialRenderSeconds = Date().timeIntervalSince(start)
        }
        openStartedAt = nil
    }

    private func applyStressModeIfNeeded() {
        #if DEBUG
        store.applyStressModeIfNeeded(chatId: chat.id, log: log)
        #endif
    }
}

struct ChatMessageItem: Hashable {
    let id: Int64
}
