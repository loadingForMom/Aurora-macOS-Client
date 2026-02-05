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

    @Environment(\.isLiveResizing) private var isLiveResizing

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
    @State private var windowMessages: [TGMessage] = []
    @State private var windowApplyToken = UUID()
    @State private var viewedMessageIds = Set<Int64>()
    @State private var visibleGroupIds = Set<String>()
    @State private var lastVisibleGroupIds = Set<String>()
    @State private var viewMessagesDebouncer = ViewMessagesDebouncer()

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

    private var bottomSentinelId: String { "bottom:\(chat.id)" }

    // MARK: - Rows

    private enum Row: Identifiable, Hashable {
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

        viewModel.loadOlder(pageSize: 80)
        store.loadMoreHistory(chatId: chat.id, anchorMessageId: anchorMessageId)
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
        Task { @MainActor [token, expectedChatId, filtered] in
            guard windowApplyToken == token else { return }
            guard chat.id == expectedChatId else { return }
            if let anchorGroupId {
                restoreAnchorGroupId = anchorGroupId
            }
            windowMessages = filtered
            let rows = buildRows(filtered)
            cachedRows = rows

            let groupIdsOrdered: [String] = rows.compactMap {
                if case .group(let g) = $0 { return g.id }
                return nil
            }
            let (bounds, ids) = buildGroupMaps(rows: rows)
            updateVisibleState(
                groupIdsOrdered: groupIdsOrdered,
                groupMessageBounds: bounds,
                groupMessageIds: ids,
                forceViewMessages: true
            )
        }
    }

    private func scheduleViewMessages(_ messageIds: Set<Int64>) {
        let unseen = messageIds.subtracting(viewedMessageIds)
        guard !unseen.isEmpty else { return }
        viewMessagesDebouncer.schedule(delay: 0.2) { [chatId = chat.id, unseen] in
            store.viewMessages(chatId: chatId, messageIds: Array(unseen), forceRead: false)
            Task { @MainActor in
                viewedMessageIds.formUnion(unseen)
            }
        }
    }

    private func scheduleViewMessagesFromVisible(groupMessageIds: [String: [Int64]]) {
        let groupIds = visibleGroupIds
        guard !groupIds.isEmpty else { return }

        let messageIds = groupIds
            .compactMap { groupMessageIds[$0] }
            .flatMap { $0 }

        guard !messageIds.isEmpty else { return }
        scheduleViewMessages(Set(messageIds))
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

        if visibilityChanged || forceViewMessages {
            scheduleViewMessagesFromVisible(groupMessageIds: groupMessageIds)
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
            .onDisappear {
                visibleGroupIds.remove(g.id)
                updateVisibleState(
                    groupIdsOrdered: groupIdsOrdered,
                    groupMessageBounds: groupMessageBounds,
                    groupMessageIds: groupMessageIds
                )
            }
        }
    }



    // MARK: - Body

    var body: some View {
        let messages = windowMessages
        let rows = cachedRows.isEmpty ? buildRows(messages) : cachedRows

#if DEBUG
        let _ = debugAssertUniqueMessageKeys(messages)
#endif

        let groupIds: [String] = rows.compactMap {
            if case .group(let g) = $0 { return g.id }
            return nil
        }
        let firstGroupId = groupIds.first
        let _ = groupIds.last
        let (groupMessageBounds, groupMessageIds) = buildGroupMaps(rows: rows)

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
                                isAtBottom = true
                                if newIncomingCount != 0 { newIncomingCount = 0 }
                            }
                            .onDisappear { isAtBottom = false }
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
                    let delta = offsetY - lastScrollOffsetY
                    lastScrollOffsetY = offsetY
                    guard !isLiveResizing else { return }
                    pushJellyImpulse(delta: delta)
                }
                .onChange(of: isLiveResizing) { _, live in
                    if live {
                        jellyDecayTask?.cancel()
                        jellyDecayTask = nil
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
                    // Build once; after that, scrolling should not re-run grouping.
                    applyWindowMessages(viewModel.messages, anchorGroupId: nil)

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
                .onChange(of: chat.id) { _, _ in
                    pagingEnabled = false
                    pagingInFlight = false
                    restoreAnchorGroupId = nil
                    lastPagingAnchorKey = nil
                    didInitialScrollToBottom = false
                    showAfterInitialJump = false
                    cachedRows = []
                    windowMessages = []
                    windowApplyToken = UUID()
                    jellyDecayTask?.cancel()
                    jellyDecayTask = nil
                    viewMessagesDebouncer.cancel()
                    viewedMessageIds = []
                    visibleGroupIds = []
                    lastVisibleGroupIds = []

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
                .onChange(of: viewModel.messages) { _, newMessages in
                    applyWindowMessages(newMessages, anchorGroupId: restoreAnchorGroupId)
                }
                .onChange(of: messages.count) { _, newCount in
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

                    let lastIsOutgoing = messages.last?.isOutgoing ?? false
                    let shouldAutoScroll = (!pagingEnabled) || isAtBottom || lastIsOutgoing

                    if shouldAutoScroll {
                        scrollToBottomSentinel(proxy, animated: pagingEnabled)
                        newIncomingCount = 0
                    } else {
                        if !lastIsOutgoing {
                            newIncomingCount += delta
                        }
                    }
                }

                // Initial open: don’t show mid-chat. Wait for layout, jump to bottom sentinel, then reveal.
                .task(id: chat.id) {
                    guard !didInitialScrollToBottom else { return }
                    showAfterInitialJump = false
                    
                    // Kick off an initial load for this chat (local + remote).
                    viewModel.loadOlder(pageSize: 80)

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
        .background(Color(nsColor: .textBackgroundColor))
    }

#if DEBUG
    private func debugAssertUniqueMessageKeys(_ messages: [TGMessage]) {
        let keys = messages.map(\.messageKey)
        let unique = Set(keys)
        assert(unique.count == keys.count, "[MessagesPane] duplicate message keys in chat \(chat.id)")
    }
#endif

    // MARK: - Grouping into rows (day headers + time separators + bubble groups)

    private func buildRows(_ msgs: [TGMessage]) -> [Row] {
        guard !msgs.isEmpty else { return [] }

        let cal = Calendar.current
        var rows: [Row] = []

        var currentDay: Date? = nil

        var bucket: [TGMessage] = []
        var curSender: Int64? = nil
        var curOutgoing: Bool = false
        var lastUnix: Int? = nil

        func flushBucket() {
            guard let first = bucket.first else { return }
            let group = MessageGroup(
                id: "\(chat.id):g:\(first.chatId):\(first.id):\(first.localId?.uuidString ?? "nil")",
                isOutgoing: curOutgoing,
                senderUserId: curSender,
                messages: bucket
            )
            rows.append(.group(group))
            bucket.removeAll(keepingCapacity: true)
        }

        func ensureDayHeader(unix: Int) {
            let d = Date(timeIntervalSince1970: TimeInterval(unix))
            let day = cal.startOfDay(for: d)
            if currentDay == nil || currentDay != day {
                flushBucket()
                currentDay = day
                let key = dayKey(day)
                rows.append(.dayHeader(id: "\(chat.id):day:\(key)", date: day))
                lastUnix = nil
            }
        }

        func maybeInsertMajorGap(prev: Int, next: Int) {
            let gap = abs(next - prev)
            guard gap >= majorGap else { return }
            rows.append(.timeSeparator(id: "\(chat.id):time:\(next)", date: Date(timeIntervalSince1970: TimeInterval(next))))
        }

        for m in msgs {
            ensureDayHeader(unix: m.date)

            if let prev = lastUnix {
                maybeInsertMajorGap(prev: prev, next: m.date)
            }

            if bucket.isEmpty {
                bucket = [m]
                curSender = m.senderUserId
                curOutgoing = m.isOutgoing
                lastUnix = m.date
                continue
            }

            let sameSender = (m.senderUserId == curSender)
            let sameDir = (m.isOutgoing == curOutgoing)
            let close = abs(m.date - (bucket.last?.date ?? m.date)) <= groupGap

            if sameSender && sameDir && close {
                bucket.append(m)
            } else {
                flushBucket()
                bucket = [m]
                curSender = m.senderUserId
                curOutgoing = m.isOutgoing
            }

            lastUnix = m.date
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
            guard case let .group(g) = row else { continue }
            let messageIds = g.messages.map { $0.id }
            guard let minId = messageIds.min(), let maxId = messageIds.max() else { continue }
            bounds[g.id] = (minId, maxId)
            ids[g.id] = messageIds
        }
        return (bounds, ids)
    }

    private func dayKey(_ d: Date) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}

private final class ViewMessagesDebouncer {
    private var workItem: DispatchWorkItem?

    func schedule(delay: TimeInterval, action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
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

struct MessageGroup: Identifiable, Hashable {
    let id: String
    let isOutgoing: Bool
    let senderUserId: Int64?
    let messages: [TGMessage]
}
