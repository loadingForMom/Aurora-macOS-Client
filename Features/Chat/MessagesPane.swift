//
//  MessagesPane.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import Foundation
import Combine
import OSLog

struct MessagesPane: View {
    static let scrollSpaceName = "Aurora.ChatScrollSpace"
    private let log = Logger(subsystem: "com.aurora.app", category: "messages.pane")

    @ObservedObject var store: TelegramStore
    let chat: TGChat
    @ObservedObject var viewModel: ChatMessagesViewModel

    @State private var pagingEnabled: Bool = false
    @State private var pagingInFlight: Bool = false
    @State private var restoreAnchorGroupId: String? = nil
    @State private var lastPagingAnchorKey: String? = nil

    // “Don’t annoy me” UX
    @State private var isAtBottom: Bool = true
    @State private var newIncomingCount: Int = 0
    @State private var lastKnownMessageCount: Int = 0

    // Cache rows so scroll-driven state updates don't force regrouping work.
    @State private var cachedRows: [Row] = []
    @State private var cachedGroupIdsOrdered: [String] = []
    @State private var cachedGroupMessageBounds: [String: (min: Int64, max: Int64)] = [:]
    @State private var cachedGroupMessageIds: [String: [Int64]] = [:]
    @State private var windowMessages: [TGMessage] = []
    @State private var rowBuildTask: Task<Void, Never>? = nil
    @State private var windowApplyToken = UUID()
    @State private var visibleGroupIds = Set<String>()
    @State private var lastVisibleGroupIds = Set<String>()

    @State private var topVisibleGroupId: String? = nil
    @State private var topVisibleMessageId: Int64? = nil
    @State private var visibleMinMessageId: Int64? = nil
    @State private var visibleMaxMessageId: Int64? = nil

    // Initial positioning: open chat at the newest message.
    @State private var didInitialScrollToBottom: Bool = false

    // Hide the list until we've jumped to bottom (prevents “show middle then jump” flash).
    @State private var showAfterInitialJump: Bool = false

    // Jelly / springy scrolling (macOS-safe)
    @State private var jellyScrollImpulse: CGFloat = 0
    @State private var lastScrollOffsetY: CGFloat = 0
    @State private var jellyDecayTask: Task<Void, Never>? = nil

    // Trackpad reveal time (iMessage-style)
    @State private var revealTimeX: CGFloat = 0
    @State private var revealGestureEngaged: Bool = false
    private let maxReveal: CGFloat = 72

    // Grouping knobs
    private let groupGap: Int = 5 * 60
    private let majorGap: Int = 60 * 60
    private static let rowBuildWorker = RowsBuildWorker()

    private var bottomSentinelId: String { "bottom:\(chat.id)" }

    // MARK: - Rows

    private enum Row: Identifiable, Hashable, Sendable {
        case dayHeader(id: String, date: Date)
        case timeSeparator(id: String, date: Date)
        case group(MessageGroup)

        var id: String {
            switch self {
            case .dayHeader(let id, _): return id
            case .timeSeparator(let id, _): return id
            case .group(let g): return g.id
            }
        }
    }

    private struct PreparedRows: Sendable {
        let rows: [Row]
        let groupIdsOrdered: [String]
        let groupMessageBounds: [String: (min: Int64, max: Int64)]
        let groupMessageIds: [String: [Int64]]
    }

    private actor RowsBuildWorker {
        private let emptyPreparedRows = PreparedRows(
            rows: [],
            groupIdsOrdered: [],
            groupMessageBounds: [:],
            groupMessageIds: [:]
        )

        func build(
            chatId: Int64,
            messages: [TGMessage],
            groupGap: Int,
            majorGap: Int
        ) -> PreparedRows {
            guard !Task.isCancelled else { return emptyPreparedRows }
            let rows = buildRows(chatId: chatId, messages: messages, groupGap: groupGap, majorGap: majorGap)
            guard !Task.isCancelled else { return emptyPreparedRows }
            let groupIdsOrdered: [String] = rows.compactMap {
                if case .group(let g) = $0 { return g.id }
                return nil
            }
            let maps = buildGroupMaps(rows: rows)
            return PreparedRows(
                rows: rows,
                groupIdsOrdered: groupIdsOrdered,
                groupMessageBounds: maps.0,
                groupMessageIds: maps.1
            )
        }

        private func buildRows(
            chatId: Int64,
            messages: [TGMessage],
            groupGap: Int,
            majorGap: Int
        ) -> [Row] {
            guard !messages.isEmpty else { return [] }

            let calendar = Calendar.current
            var rows: [Row] = []
            var currentDay: Date? = nil

            var bucket: [TGMessage] = []
            var curSender: Int64? = nil
            var curOutgoing: Bool = false
            var lastUnix: Int? = nil

            func flushBucket() {
                guard let first = bucket.first else { return }
                let group = MessageGroup(
                    id: "\(chatId):g:\(first.chatId):\(first.id):\(first.localId?.uuidString ?? "nil")",
                    isOutgoing: curOutgoing,
                    senderUserId: curSender,
                    messages: bucket
                )
                rows.append(.group(group))
                bucket.removeAll(keepingCapacity: true)
            }

            func ensureDayHeader(unix: Int) {
                let date = Date(timeIntervalSince1970: TimeInterval(unix))
                let day = calendar.startOfDay(for: date)
                if currentDay == nil || currentDay != day {
                    flushBucket()
                    currentDay = day
                    let key = dayKey(day, calendar: calendar)
                    rows.append(.dayHeader(id: "\(chatId):day:\(key)", date: day))
                    lastUnix = nil
                }
            }

            func maybeInsertMajorGap(prev: Int, next: Int) {
                let gap = abs(next - prev)
                guard gap >= majorGap else { return }
                rows.append(.timeSeparator(id: "\(chatId):time:\(next)", date: Date(timeIntervalSince1970: TimeInterval(next))))
            }

            for message in messages {
                if Task.isCancelled { return [] }
                ensureDayHeader(unix: message.date)

                if let prev = lastUnix {
                    maybeInsertMajorGap(prev: prev, next: message.date)
                }

                if bucket.isEmpty {
                    bucket = [message]
                    curSender = message.senderUserId
                    curOutgoing = message.isOutgoing
                    lastUnix = message.date
                    continue
                }

                let sameSender = (message.senderUserId == curSender)
                let sameDirection = (message.isOutgoing == curOutgoing)
                let close = abs(message.date - (bucket.last?.date ?? message.date)) <= groupGap

                if sameSender && sameDirection && close {
                    bucket.append(message)
                } else {
                    flushBucket()
                    bucket = [message]
                    curSender = message.senderUserId
                    curOutgoing = message.isOutgoing
                }

                lastUnix = message.date
            }

            flushBucket()
            return rows
        }

        private func buildGroupMaps(rows: [Row]) -> ([String: (min: Int64, max: Int64)], [String: [Int64]]) {
            var bounds: [String: (min: Int64, max: Int64)] = [:]
            var ids: [String: [Int64]] = [:]
            bounds.reserveCapacity(rows.count)
            ids.reserveCapacity(rows.count)
            for row in rows {
                if Task.isCancelled {
                    return ([:], [:])
                }
                guard case let .group(group) = row else { continue }
                let messageIds = group.messages.map(\.id)
                guard let minId = messageIds.min(), let maxId = messageIds.max() else { continue }
                bounds[group.id] = (minId, maxId)
                ids[group.id] = messageIds
            }
            return (bounds, ids)
        }

        private func dayKey(_ day: Date, calendar: Calendar) -> String {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        }
    }

    // MARK: - Paging

    private func requestOlderHistory(anchorGroupId: String?, anchorMessageId: Int64?) {
        guard pagingEnabled else { return }
        guard !pagingInFlight else { return }
        guard !store.isLoadingHistory else { return }
        guard let anchorGroupId, let anchorMessageId else { return }

        // Prevent “double fire” when SwiftUI reuses/rebuilds the top area.
        let key = "\(anchorGroupId):\(anchorMessageId)"
        if lastPagingAnchorKey == key { return }
        lastPagingAnchorKey = key

        restoreAnchorGroupId = anchorGroupId
        pagingInFlight = true

        let targetChatId = chat.id
        Task { @MainActor [targetChatId, anchorMessageId] in
            await Task.yield()
            guard chat.id == targetChatId else { return }
            viewModel.loadOlder(pageSize: 80)
            store.loadMoreHistory(chatId: targetChatId, anchorMessageId: anchorMessageId)
        }
    }

    private func applyWindowMessages(_ messages: [TGMessage], anchorGroupId: String?) {
        let expectedChatId = chat.id
        let token = windowApplyToken
        let filtered = messages.filter { $0.chatId == expectedChatId }
        let dropped = messages.count - filtered.count
        if dropped > 0 {
            log.debug("dropped \(dropped, privacy: .public) messages not in chat \(expectedChatId, privacy: .public)")
        }

        if filtered.isEmpty, !messages.isEmpty {
#if DEBUG
            log.debug("filtered out all rows chatId=\(expectedChatId, privacy: .public)")
#endif
        }
        let shouldForceViewMessages = windowMessages.isEmpty
        rowBuildTask?.cancel()
        rowBuildTask = Task { @MainActor [token, expectedChatId, filtered, anchorGroupId, shouldForceViewMessages] in
            let prepared = await Self.rowBuildWorker.build(
                chatId: expectedChatId,
                messages: filtered,
                groupGap: groupGap,
                majorGap: majorGap
            )
            guard !Task.isCancelled else { return }
            guard windowApplyToken == token else { return }
            guard chat.id == expectedChatId else { return }
            if let anchorGroupId {
                restoreAnchorGroupId = anchorGroupId
            }
            windowMessages = filtered
            cachedRows = prepared.rows
            cachedGroupIdsOrdered = prepared.groupIdsOrdered
            cachedGroupMessageBounds = prepared.groupMessageBounds
            cachedGroupMessageIds = prepared.groupMessageIds
            updateVisibleState(
                groupIdsOrdered: prepared.groupIdsOrdered,
                groupMessageBounds: prepared.groupMessageBounds,
                groupMessageIds: prepared.groupMessageIds,
                forceViewMessages: shouldForceViewMessages
            )
        }
    }

    private func reportVisibleRange(
        minMessageId: Int64?,
        maxMessageId: Int64?,
        groupMessageIds: [String: [Int64]]
    ) {
        let groupIds = visibleGroupIds
        guard !groupIds.isEmpty else { return }

        let messageIds = groupIds
            .compactMap { groupMessageIds[$0] }
            .flatMap { $0 }

        guard !messageIds.isEmpty else { return }
        let firstId = messageIds.min().map(String.init) ?? "n/a"
        let lastId = messageIds.max().map(String.init) ?? "n/a"
        let lo = minMessageId.map(String.init) ?? "n/a"
        let hi = maxMessageId.map(String.init) ?? "n/a"
        SwiftUIPublishTrace.uiEvent(
            name: "onPreferenceChange_visibleRange",
            chatId: chat.id,
            payload: "range=\(lo)..\(hi) count=\(messageIds.count) visibleIdsCount=\(messageIds.count) first=\(firstId) last=\(lastId)",
            reason: "fromVisibleRange"
        )
        store.reportVisibleMessages(
            chatId: chat.id,
            minMessageId: minMessageId,
            maxMessageId: maxMessageId,
            messageIds: messageIds
        )
    }

    @MainActor
    private func updateVisibleState(
        groupIdsOrdered: [String],
        groupMessageBounds: [String: (min: Int64, max: Int64)],
        groupMessageIds: [String: [Int64]],
        forceViewMessages: Bool = false
    ) {
        let currentVisible = visibleGroupIds
        let visibilityChanged = currentVisible != lastVisibleGroupIds
        if visibilityChanged {
            lastVisibleGroupIds = currentVisible
            let visibleIds = currentVisible
                .compactMap { groupMessageIds[$0] }
                .flatMap { $0 }
            let firstId = visibleIds.min().map(String.init) ?? "n/a"
            let lastId = visibleIds.max().map(String.init) ?? "n/a"
            SwiftUIPublishTrace.uiEvent(
                name: "onChange_visibleMessageIds",
                chatId: chat.id,
                payload: "visibleIdsCount=\(visibleIds.count) first=\(firstId) last=\(lastId)",
                reason: "fromVisibleRange"
            )
        }

        let visibleBounds = currentVisible.compactMap { groupMessageBounds[$0] }
        let newMin = visibleBounds.map(\.min).min()
        let newMax = visibleBounds.map(\.max).max()
        let newTopGroup = groupIdsOrdered.first(where: { currentVisible.contains($0) })
        let newTopMessageId = newTopGroup.flatMap { groupMessageBounds[$0]?.min }

        let boundsChanged = newMin != visibleMinMessageId || newMax != visibleMaxMessageId
        let anchorChanged = newTopGroup != topVisibleGroupId || newTopMessageId != topVisibleMessageId

        if boundsChanged || anchorChanged {
            visibleMinMessageId = newMin
            visibleMaxMessageId = newMax
            topVisibleGroupId = newTopGroup
            topVisibleMessageId = newTopMessageId
        }

        if boundsChanged || forceViewMessages {
            reportVisibleRange(
                minMessageId: newMin,
                maxMessageId: newMax,
                groupMessageIds: groupMessageIds
            )
        }
    }

    private var pagingStateLabel: String {
        if pagingInFlight { return "paging=loading" }
        return pagingEnabled ? "paging=ready" : "paging=disabled"
    }

    private func debugId(_ value: Int64?) -> String {
        guard let value else { return "n/a" }
        return "\(value)"
    }

    // MARK: - Scrolling helpers

    private func scrollToBottom(_ proxy: ScrollViewProxy, lastGroupId: String?, animated: Bool) {
        guard let lastGroupId else { return }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(lastGroupId, anchor: .bottom)
            }
        } else {
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                proxy.scrollTo(lastGroupId, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomSentinel(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomSentinelId, anchor: .bottom)
            }
        } else {
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                proxy.scrollTo(bottomSentinelId, anchor: .bottom)
            }
        }
    }

    private func scrollToAnchorTop(_ proxy: ScrollViewProxy, anchorId: String) {
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
    }

    // MARK: - Jelly update (throttled + spring back)

    private func pushJellyImpulse(delta: CGFloat) {
        // Stronger and smoother: clamp larger, quantize smaller.
        let clamped = max(-700, min(700, delta))
        let quantized = (clamped / 4).rounded() * 4

        if quantized == jellyScrollImpulse { return }
        jellyScrollImpulse = quantized

        jellyDecayTask?.cancel()
        jellyDecayTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000) // ~45ms
            await MainActor.run {
                withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.62, blendDuration: 0.10)) {
                    jellyScrollImpulse = 0
                }
            }
        }
    }

    // MARK: - Trackpad gesture for timestamps

    private var revealGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                let dx = v.translation.width
                let dy = v.translation.height

                if !revealGestureEngaged {
                    // Engage only when it's clearly horizontal.
                    guard abs(dx) > abs(dy) * 1.25 else { return }
                    revealGestureEngaged = true
                }

                let r = min(maxReveal, max(0, -dx))
                revealTimeX = r
            }
            .onEnded { _ in
                revealGestureEngaged = false
                withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.72, blendDuration: 0.10)) {
                    revealTimeX = 0
                }
            }
    }

    // MARK: - Row rendering (helps compiler + performance)

    @ViewBuilder
    private func rowView(
        _ row: Row,
        firstGroupId: String?,
        groupIdsOrdered: [String],
        groupMessageBounds: [String: (min: Int64, max: Int64)],
        groupMessageIds: [String: [Int64]]
    ) -> some View {
        switch row {
        case .dayHeader(_, let day):
            DayHeaderView(day: day)

        case .timeSeparator(_, let t):
            TimeSeparatorView(date: t)

        case .group(let g):
            ChatMessageGroupView(
                store: store,
                chat: chat,
                group: g,
                revealTimeX: revealTimeX,
                jellyScrollImpulse: jellyScrollImpulse
            )
            .id(g.id)
            .onAppear {
                SwiftUIPublishTrace.uiEvent(
                    name: "onAppear_messageGroup",
                    chatId: chat.id,
                    payload: "groupId=\(g.id) count=\(g.messages.count)",
                    reason: "messageGroupVisibility"
                )
                DispatchQueue.main.async {
                    visibleGroupIds.insert(g.id)
                    updateVisibleState(
                        groupIdsOrdered: groupIdsOrdered,
                        groupMessageBounds: groupMessageBounds,
                        groupMessageIds: groupMessageIds
                    )

                    // Trigger paging only when we actually reach the top of what's loaded.
                    guard pagingEnabled, !pagingInFlight, !store.isLoadingHistory else { return }

                    // Never page during the initial hidden render / jump-to-bottom sequence.
                    guard didInitialScrollToBottom, showAfterInitialJump else { return }

                    guard let firstGroupId, g.id == firstGroupId else { return }
                    // Don't page while user is already at the bottom (initial open / reading newest).
                    guard !isAtBottom else { return }

                    let anchorGroupId = topVisibleGroupId ?? g.id
                    let anchorMessageId = topVisibleMessageId ?? g.messages.first?.id
                    requestOlderHistory(anchorGroupId: anchorGroupId, anchorMessageId: anchorMessageId)
                }
            }
            .onDisappear {
                SwiftUIPublishTrace.uiEvent(
                    name: "onDisappear_messageGroup",
                    chatId: chat.id,
                    payload: "groupId=\(g.id) count=\(g.messages.count)",
                    reason: "messageGroupVisibility"
                )
                DispatchQueue.main.async {
                    visibleGroupIds.remove(g.id)
                    updateVisibleState(
                        groupIdsOrdered: groupIdsOrdered,
                        groupMessageBounds: groupMessageBounds,
                        groupMessageIds: groupMessageIds
                    )
                }
            }
        }
    }



    // MARK: - Body

    var body: some View {
        let messages = windowMessages
        let rows = cachedRows

#if DEBUG
        let _ = debugAssertUniqueMessageKeys(messages)
#endif

        let groupIds = cachedGroupIdsOrdered
        let firstGroupId = groupIds.first
        let groupMessageBounds = cachedGroupMessageBounds
        let groupMessageIds = cachedGroupMessageIds

        ScrollViewReader { proxy in
            ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Scroll offset reader (macOS-safe).
                        ScrollOffsetReader()
                            .frame(height: 0)

                        ForEach(rows) { row in
                            rowView(
                                row,
                                firstGroupId: firstGroupId,
                                groupIdsOrdered: groupIds,
                                groupMessageBounds: groupMessageBounds,
                                groupMessageIds: groupMessageIds
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomSentinelId)
                            .onAppear {
                                SwiftUIPublishTrace.uiEvent(
                                    name: "onAppear_bottomSentinel",
                                    chatId: chat.id,
                                    payload: "isAtBottom=true incomingCount=\(newIncomingCount)",
                                    reason: "scrollPosition"
                                )
                                DispatchQueue.main.async {
                                    isAtBottom = true
                                    if newIncomingCount != 0 { newIncomingCount = 0 }
                                }
                            }
                            .onDisappear {
                                SwiftUIPublishTrace.uiEvent(
                                    name: "onDisappear_bottomSentinel",
                                    chatId: chat.id,
                                    payload: "isAtBottom=false",
                                    reason: "scrollPosition"
                                )
                                DispatchQueue.main.async {
                                    isAtBottom = false
                                }
                            }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .opacity(showAfterInitialJump ? 1 : 0)
                .allowsHitTesting(showAfterInitialJump)
                .animation(nil, value: showAfterInitialJump)
                .coordinateSpace(name: Self.scrollSpaceName)
                .simultaneousGesture(revealGesture)
                .onPreferenceChange(ScrollOffsetKey.self) { minY in
                    let offsetY = -minY
                    DispatchQueue.main.async {
                        let delta = offsetY - lastScrollOffsetY
                        lastScrollOffsetY = offsetY
                        SwiftUIPublishTrace.uiEvent(
                            name: "onPreferenceChange_scrollOffset",
                            chatId: chat.id,
                            payload: "offsetY=\(Int(offsetY.rounded())) delta=\(Int(delta.rounded()))",
                            reason: "scrollGeometryPreference"
                        )
                        pushJellyImpulse(delta: delta)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if newIncomingCount > 0 && !isAtBottom {
                        Button {
                            scrollToBottomSentinel(proxy, animated: true)
                            newIncomingCount = 0
                            isAtBottom = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(newIncomingCount) новых")
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(.regularMaterial, in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18)
                        .padding(.bottom, 84)
                    }
                }
                .overlay(alignment: .topLeading) {
#if DEBUG
                    VStack(alignment: .leading, spacing: 4) {
                        Text("chatId=\(chat.id)")
                        Text("visible=\(debugId(visibleMinMessageId))…\(debugId(visibleMaxMessageId))")
                        Text(pagingStateLabel)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
#endif
                }
                .onAppear {
                    SwiftUIPublishTrace.uiEvent(
                        name: "onAppear_messagesPane",
                        chatId: chat.id,
                        payload: "initialCount=\(viewModel.messages.count)",
                        reason: "viewLifecycle"
                    )
                    // Build once; after that, scrolling should not re-run grouping.
                    applyWindowMessages(viewModel.messages, anchorGroupId: nil)
                    DispatchQueue.main.async {
                        lastKnownMessageCount = messages.count
                        newIncomingCount = 0

                        // Reset paging state for this chat. We enable paging only after we jump to bottom.
                        pagingEnabled = false
                        didInitialScrollToBottom = false
                        showAfterInitialJump = false
                        lastPagingAnchorKey = nil
                        restoreAnchorGroupId = nil
                        pagingInFlight = false

                        topVisibleGroupId = nil
                        topVisibleMessageId = nil
                        visibleMinMessageId = nil
                        visibleMaxMessageId = nil
                        visibleGroupIds = []
                        lastVisibleGroupIds = []
                    }
                }
                .onChange(of: chat.id) { oldChatId, _ in
                    SwiftUIPublishTrace.uiEvent(
                        name: "onChange_chatId",
                        chatId: oldChatId,
                        payload: "oldChatId=\(oldChatId) newChatId=\(chat.id)",
                        reason: "fromSelectionChange"
                    )
                    DispatchQueue.main.async {
                        pagingEnabled = false
                        pagingInFlight = false
                        restoreAnchorGroupId = nil
                        lastPagingAnchorKey = nil
                        didInitialScrollToBottom = false
                        showAfterInitialJump = false
                        cachedRows = []
                        cachedGroupIdsOrdered = []
                        cachedGroupMessageBounds = [:]
                        cachedGroupMessageIds = [:]
                        windowMessages = []
                        rowBuildTask?.cancel()
                        rowBuildTask = nil
                        windowApplyToken = UUID()
                        jellyDecayTask?.cancel()
                        jellyDecayTask = nil
                        visibleGroupIds = []
                        lastVisibleGroupIds = []
                        store.resetVisibleMessageTracking(chatId: oldChatId)

                        isAtBottom = true
                        newIncomingCount = 0
                        lastKnownMessageCount = 0

                        revealTimeX = 0
                        revealGestureEngaged = false

                        topVisibleGroupId = nil
                        topVisibleMessageId = nil
                        visibleMinMessageId = nil
                        visibleMaxMessageId = nil
                    }
                }
                .onDisappear {
                    SwiftUIPublishTrace.uiEvent(
                        name: "onDisappear_messagesPane",
                        chatId: chat.id,
                        payload: "visibleRange=\(debugId(visibleMinMessageId))..\(debugId(visibleMaxMessageId))",
                        reason: "viewLifecycle"
                    )
                    rowBuildTask?.cancel()
                    rowBuildTask = nil
                    store.resetVisibleMessageTracking(chatId: chat.id)
                }
                .onChange(of: viewModel.messages) { _, newMessages in
                    SwiftUIPublishTrace.uiEvent(
                        name: "onChange_viewModelMessages",
                        chatId: chat.id,
                        payload: "count=\(newMessages.count)",
                        reason: "fromSnapshotStream"
                    )
                    applyWindowMessages(newMessages, anchorGroupId: restoreAnchorGroupId)
                }
                .onChange(of: messages.count) { _, newCount in
                    let snapshot = messages
                    DispatchQueue.main.async {
                        // During the initial hidden render + jump-to-bottom, do not auto-show or auto-scroll.
                        guard didInitialScrollToBottom else {
                            lastKnownMessageCount = newCount
                            newIncomingCount = 0
                            return
                        }

                        if newCount < lastKnownMessageCount {
                            lastKnownMessageCount = newCount
                            newIncomingCount = 0
                            return
                        }

                        if pagingInFlight, let anchorId = restoreAnchorGroupId {
                            scrollToAnchorTop(proxy, anchorId: anchorId)
                            restoreAnchorGroupId = nil
                            pagingInFlight = false
                            lastKnownMessageCount = newCount
                            return
                        }

                        let delta = newCount - lastKnownMessageCount
                        lastKnownMessageCount = newCount
                        guard delta > 0 else { return }

                        let lastIsOutgoing = snapshot.last?.isOutgoing ?? false
                        let shouldAutoScroll = (!pagingEnabled) || isAtBottom || lastIsOutgoing

                        if shouldAutoScroll {
                            scrollToBottomSentinel(proxy, animated: pagingEnabled)
                            newIncomingCount = 0
                        } else if !lastIsOutgoing {
                            newIncomingCount += delta
                        }
                    }
                }

                // Initial open: don’t show mid-chat. Wait for layout, jump to bottom sentinel, then reveal.
                .task(id: chat.id) {
                    guard !didInitialScrollToBottom else { return }
                    showAfterInitialJump = false

                    // Let SwiftUI finish initial layout passes.
                    await Task.yield()
                    await Task.yield()

                    await MainActor.run {
                        scrollToBottomSentinel(proxy, animated: false)
                    }

                    // One more yield + re-scroll makes this robust when rows/height change right after first render.
                    await Task.yield()
                    await MainActor.run {
                        scrollToBottomSentinel(proxy, animated: false)
                        didInitialScrollToBottom = true
                        isAtBottom = true
                        pagingEnabled = true
                        showAfterInitialJump = true
                    }
                }
        }
        .id(chat.id)
        .transaction { _ in
            ViewUpdatePhaseTracker.shared.markUpdating(source: "MessagesPane")
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

#if DEBUG
    private func debugAssertUniqueMessageKeys(_ messages: [TGMessage]) {
        let keys = messages.map(\.messageKey)
        let unique = Set(keys)
        assert(unique.count == keys.count, "[MessagesPane] duplicate message keys in chat \(chat.id)")
    }
#endif
}

// MARK: - Scroll tracking (macOS-safe)

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollOffsetReader: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .preference(
                    key: ScrollOffsetKey.self,
                    value: geo.frame(in: .named(MessagesPane.scrollSpaceName)).minY
                )
        }
    }
}

// MARK: - Day header + time separator (cached formatters)

private enum ChatFormatters {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

private struct DayHeaderView: View {
    let day: Date

    var body: some View {
        Text(dayLabel(day))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return ChatFormatters.dayFormatter.string(from: d)
    }
}

private struct TimeSeparatorView: View {
    let date: Date

    var body: some View {
        Text(ChatFormatters.timeFormatter.string(from: date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

struct MessageGroup: Identifiable, Hashable, Sendable {
    let id: String
    let isOutgoing: Bool
    let senderUserId: Int64?
    let messages: [TGMessage]
}
