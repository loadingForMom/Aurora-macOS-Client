//
//  MessagesPane.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import Foundation

struct MessagesPane: View {
    static let scrollSpaceName = "Aurora.ChatScrollSpace"

    @ObservedObject var store: TelegramStore
    let chat: TGChat

    @State private var pagingEnabled: Bool = false
    @State private var pagingInFlight: Bool = false
    @State private var restoreAnchorGroupId: String? = nil
    @State private var lastPagingAnchor: String? = nil

    // “Don’t annoy me” UX
    @State private var isAtBottom: Bool = true
    @State private var newIncomingCount: Int = 0
    @State private var lastKnownMessageCount: Int = 0

    // Cache rows so scroll-driven state updates don't force regrouping work.
    @State private var cachedRows: [Row] = []
    @State private var windowMessages: [TGMessage] = []
    @State private var windowApplyToken = UUID()

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
    @State private var jellyContainerHeight: CGFloat = 0
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
        case dayHeader(Date)
        case timeSeparator(Date)
        case group(MessageGroup)

        var id: String {
            switch self {
            case .dayHeader(let d): return "day:\(Self.dayKey(d))"
            case .timeSeparator(let d): return "time:\(Int(d.timeIntervalSince1970))"
            case .group(let g): return g.id
            }
        }

        private static func dayKey(_ d: Date) -> String {
            let cal = Calendar.current
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        }
    }

    // MARK: - Paging

    private func requestOlderHistory(anchorGroupId: String?, anchorMessageId: Int64?) {
        guard pagingEnabled else { return }
        guard !pagingInFlight else { return }
        guard !store.isLoadingHistory else { return }
        guard let anchorGroupId, let anchorMessageId else { return }

        // Prevent “double fire” when SwiftUI reuses/rebuilds the top area.
        if lastPagingAnchor == anchorGroupId { return }
        lastPagingAnchor = anchorGroupId

        restoreAnchorGroupId = anchorGroupId
        pagingInFlight = true

        fetchOlderMessages(beforeMessageId: anchorMessageId, anchorGroupId: anchorGroupId)
        store.loadMoreHistory(chatId: chat.id, anchorMessageId: anchorMessageId)
    }

    private func fetchLatestMessages() {
        guard let repo = store.databaseRepository else { return }
        let limit = store.historyWindowLimitByChatId[chat.id] ?? 160
        let latest = repo.fetchLatestMessages(chatId: chat.id, limit: limit)
        applyWindowMessages(store.sortChronological(latest), anchorGroupId: nil)
    }

    private func fetchOlderMessages(beforeMessageId: Int64, anchorGroupId: String) {
        guard let repo = store.databaseRepository else { return }
        let older = repo.fetchOlderMessages(chatId: chat.id, beforeMessageId: beforeMessageId, limit: 80)
        guard !older.isEmpty else { return }
        let sortedOlder = store.sortChronological(older)
        let existingKeys = Set(windowMessages.map { $0.messageKey })
        let filteredOlder = sortedOlder.filter { !existingKeys.contains($0.messageKey) }
        guard !filteredOlder.isEmpty else { return }
        applyWindowMessages(filteredOlder + windowMessages, anchorGroupId: anchorGroupId)
    }

    private func applyWindowMessages(_ messages: [TGMessage], anchorGroupId: String?) {
        let expectedChatId = chat.id
        let token = windowApplyToken
        let filtered = messages.filter { $0.chatId == expectedChatId }
        let dropped = messages.count - filtered.count
        if dropped > 0 {
            print("[DB WINDOW] dropped \(dropped) messages not in chat \(expectedChatId)")
        }

        DispatchQueue.main.async { [token, expectedChatId, filtered] in
            guard windowApplyToken == token else { return }
            guard chat.id == expectedChatId else { return }
            if let anchorGroupId {
                restoreAnchorGroupId = anchorGroupId
            }
            windowMessages = filtered
            cachedRows = buildRows(filtered)
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
    private func rowView(_ row: Row, firstGroupId: String?) -> some View {
        switch row {
        case .dayHeader(let day):
            DayHeaderView(day: day)

        case .timeSeparator(let t):
            TimeSeparatorView(date: t)

        case .group(let g):
            ChatMessageGroupView(
                store: store,
                chat: chat,
                group: g,
                revealTimeX: revealTimeX,
                jellyScrollImpulse: jellyScrollImpulse,
                jellyContainerHeight: jellyContainerHeight
            )
            .id(g.id)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: GroupFrameKey.self,
                        value: [g.id: geo.frame(in: .named(MessagesPane.scrollSpaceName))]
                    )
                }
            )
            .onAppear {
                // Trigger paging only when we actually reach the top of what's loaded.
                guard pagingEnabled, !pagingInFlight, !store.isLoadingHistory else { return }
                guard let firstGroupId, g.id == firstGroupId else { return }
                // Don't page while user is already at the bottom (initial open / reading newest).
                guard !isAtBottom else { return }
                let anchorGroupId = topVisibleGroupId ?? g.id
                let anchorMessageId = topVisibleMessageId ?? g.messages.first?.id
                requestOlderHistory(anchorGroupId: anchorGroupId, anchorMessageId: anchorMessageId)
            }
        }
    }



    // MARK: - Body

    var body: some View {
        let storeMessages = store.messagesByChatId[chat.id] ?? []
        let messages = windowMessages
        let rows = cachedRows.isEmpty ? buildRows(messages) : cachedRows

        let groupIds: [String] = rows.compactMap {
            if case .group(let g) = $0 { return g.id }
            return nil
        }
        let firstGroupId = groupIds.first
        let lastGroupId = groupIds.last
        let groupMessageBounds: [String: (min: Int64, max: Int64)] = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard case let .group(g) = row else { return nil }
                guard let minId = g.messages.min(by: { $0.id < $1.id })?.id else { return nil }
                guard let maxId = g.messages.max(by: { $0.id < $1.id })?.id else { return nil }
                return (g.id, (minId, maxId))
            }
        )

        ScrollViewReader { proxy in
            GeometryReader { containerGeo in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Scroll offset reader (macOS-safe).
                        ScrollOffsetReader()
                            .frame(height: 0)

                        ForEach(rows) { row in
                            rowView(row, firstGroupId: firstGroupId)
                        }

                        if store.showLogs {
                            Divider().padding(.vertical, 10)
                            Text(store.logs.joined(separator: "\n\n"))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .textSelection(.enabled)
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
                    pushJellyImpulse(delta: delta)
                }
                .onPreferenceChange(GroupFrameKey.self) { frames in
                    DispatchQueue.main.async {
                        let visibleGroups = frames.filter { $0.value.maxY >= 0 && $0.value.minY <= jellyContainerHeight }
                        let visibleBounds = visibleGroups.compactMap { groupMessageBounds[$0.key] }

                        visibleMinMessageId = visibleBounds.map(\.min).min()
                        visibleMaxMessageId = visibleBounds.map(\.max).max()

                        if let topVisible = visibleGroups.min(by: { $0.value.minY < $1.value.minY }),
                           let bounds = groupMessageBounds[topVisible.key] {
                            topVisibleGroupId = topVisible.key
                            topVisibleMessageId = bounds.min
                        }
                    }
                }
                .onAppear {
                    jellyContainerHeight = containerGeo.size.height
                }
                .onChange(of: containerGeo.size.height) { _, newH in
                    jellyContainerHeight = newH
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
                    cachedRows = buildRows(messages)
                    fetchLatestMessages()

                    lastKnownMessageCount = messages.count
                    newIncomingCount = 0

                    // Reset paging state for this chat. We enable paging only after we jump to bottom.
                    pagingEnabled = false
                    didInitialScrollToBottom = false
                    showAfterInitialJump = false
                    lastPagingAnchor = nil
                    restoreAnchorGroupId = nil
                    pagingInFlight = false

                    topVisibleGroupId = nil
                    topVisibleMessageId = nil
                    visibleMinMessageId = nil
                    visibleMaxMessageId = nil
                }
                .onChange(of: chat.id) { _, _ in
                    pagingEnabled = false
                    pagingInFlight = false
                    restoreAnchorGroupId = nil
                    lastPagingAnchor = nil
                    didInitialScrollToBottom = false
                    showAfterInitialJump = false
                    cachedRows = []
                    windowMessages = []
                    windowApplyToken = UUID()

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
                .onChange(of: storeMessages.count) { _, _ in
                    fetchLatestMessages()
                }
                .onChange(of: messages.count) { _, newCount in
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
                        if !pagingEnabled {
                            pagingEnabled = true
                            didInitialScrollToBottom = true
                        }
                        // If we got here during initial load, ensure the list becomes visible.
                        if !showAfterInitialJump {
                            showAfterInitialJump = true
                        }
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
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

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
                id: "g:\(first.chatId):\(first.id)",
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
                rows.append(.dayHeader(day))
                lastUnix = nil
            }
        }

        func maybeInsertMajorGap(prev: Int, next: Int) {
            let gap = abs(next - prev)
            guard gap >= majorGap else { return }
            rows.append(.timeSeparator(Date(timeIntervalSince1970: TimeInterval(next))))
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
}

// MARK: - Scroll tracking (macOS-safe)

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct GroupFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
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
