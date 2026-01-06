//
//  MessagesPane.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct MessagesPane: View {
    static let scrollSpaceName = "Aurora.ChatScrollSpace"

    @ObservedObject var store: TelegramStore
    let chat: TGChat

    @State private var pagingEnabled: Bool = false
    @State private var pagingInFlight: Bool = false
    @State private var restoreAnchorGroupId: String? = nil

    // MARK: - “Don’t annoy me” UX

    @State private var isAtBottom: Bool = true
    @State private var newIncomingCount: Int = 0
    @State private var lastKnownMessageCount: Int = 0

    // MARK: - Jelly / springy scrolling (macOS-safe)

    @State private var jellyScrollImpulse: CGFloat = 0
    @State private var jellyContainerHeight: CGFloat = 0

    @State private var lastScrollOffsetY: CGFloat = 0
    @State private var jellyDecayTask: Task<Void, Never>? = nil

    // MARK: - Trackpad reveal time (iMessage-style)

    @State private var revealTimeX: CGFloat = 0
    @State private var revealGestureEngaged: Bool = false

    private let maxReveal: CGFloat = 72

    // MARK: - Grouping knobs

    private let groupGap: Int = 5 * 60          // messages in same bubble-group if within 5 min
    private let majorGap: Int = 60 * 60         // insert time separator if gap >= 60 min

    private var bottomSentinelId: String { "bottom:\(chat.id)" }

    // MARK: - Rows

    private enum ChatRow: Identifiable, Hashable {
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

    private func requestOlderHistory(anchorGroupId: String?) {
        guard pagingEnabled else { return }
        guard !pagingInFlight else { return }
        guard !store.isLoadingHistory else { return }
        guard let anchorGroupId else { return }

        restoreAnchorGroupId = anchorGroupId
        pagingInFlight = true
        store.loadMoreHistory(chatId: chat.id)
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

    private func scrollToAnchorTop(_ proxy: ScrollViewProxy, anchorId: String) {
        var t = Transaction()
        t.animation = nil
        withTransaction(t) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
    }

    // MARK: - Jelly update (throttled + spring back)

    private func pushJellyImpulse(delta: CGFloat) {
        // Clamp + quantize to reduce state churn.
        let clamped = max(-220, min(220, delta))
        let quantized = (clamped / 10).rounded() * 10

        if quantized == jellyScrollImpulse { return }
        jellyScrollImpulse = quantized

        // Debounced decay back to 0 (spring).
        jellyDecayTask?.cancel()
        jellyDecayTask = Task {
            try? await Task.sleep(nanoseconds: 55_000_000) // ~55ms
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

                // Engage only if it’s clearly horizontal (trackpad swipe), otherwise let ScrollView do its job.
                if !revealGestureEngaged {
                    guard abs(dx) > abs(dy) * 1.25 else { return }
                    revealGestureEngaged = true
                }

                // Swipe left => reveal grows.
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

    // MARK: - Row rendering (split out to help the compiler type-check faster)

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
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
        }
    }

    // MARK: - Body

    var body: some View {
        let messages = store.messagesByChatId[chat.id] ?? []
        let rows = buildRows(messages)

        let firstGroupId = rows.compactMap { row -> String? in
            if case .group(let g) = row { return g.id }
            return nil
        }.first

        let lastGroupId = rows.compactMap { row -> String? in
            if case .group(let g) = row { return g.id }
            return nil
        }.last

        ScrollViewReader { proxy in
            GeometryReader { containerGeo in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // Top sentinel for paging (older history).
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                requestOlderHistory(anchorGroupId: firstGroupId)
                            }

                        // Scroll offset reader (macOS-safe).
                        ScrollOffsetReader()
                            .frame(height: 0)

                        ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                            rowView(row)
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
                .coordinateSpace(name: Self.scrollSpaceName)
                .simultaneousGesture(revealGesture)
                .onPreferenceChange(ScrollOffsetKey.self) { minY in
                    // In our reader: minY decreases when scrolling down, so offsetY is -minY.
                    let offsetY = -minY
                    let delta = offsetY - lastScrollOffsetY
                    lastScrollOffsetY = offsetY
                    pushJellyImpulse(delta: delta)
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
                            scrollToBottom(proxy, lastGroupId: lastGroupId, animated: true)
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
                .onAppear {
                    lastKnownMessageCount = messages.count
                    newIncomingCount = 0
                }
                .onChange(of: chat.id) { _, _ in
                    pagingEnabled = false
                    pagingInFlight = false
                    restoreAnchorGroupId = nil

                    isAtBottom = true
                    newIncomingCount = 0
                    lastKnownMessageCount = 0

                    revealTimeX = 0
                    revealGestureEngaged = false
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
                        scrollToBottom(proxy, lastGroupId: lastGroupId, animated: pagingEnabled)
                        newIncomingCount = 0

                        if !pagingEnabled { pagingEnabled = true }
                    } else {
                        if !lastIsOutgoing {
                            newIncomingCount += delta
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Grouping into rows (day headers + time separators + bubble groups)

    private func buildRows(_ msgs: [TGMessage]) -> [ChatRow] {
        guard !msgs.isEmpty else { return [] }

        let cal = Calendar.current

        // Assume msgs are already sorted by date ascending. If not, uncomment:
        // let msgs = msgs.sorted { $0.date < $1.date }

        var rows: [ChatRow] = []

        var currentDay: Date? = nil

        var bucket: [TGMessage] = []
        var curSender: Int64? = nil
        var curOutgoing: Bool = false
        var lastMessageDate: Int? = nil

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

        func ensureDayHeader(for unix: Int) {
            let d = Date(timeIntervalSince1970: TimeInterval(unix))
            let day = cal.startOfDay(for: d)
            if currentDay == nil || day != currentDay {
                // New day: close previous group cleanly.
                flushBucket()
                currentDay = day
                rows.append(.dayHeader(day))
                lastMessageDate = nil
            }
        }

        func maybeInsertMajorGapSeparator(prevUnix: Int, nextUnix: Int) {
            let gap = abs(nextUnix - prevUnix)
            guard gap >= majorGap else { return }
            let t = Date(timeIntervalSince1970: TimeInterval(nextUnix))
            rows.append(.timeSeparator(t))
        }

        for m in msgs {
            ensureDayHeader(for: m.date)

            if let prev = lastMessageDate {
                maybeInsertMajorGapSeparator(prevUnix: prev, nextUnix: m.date)
            }

            if bucket.isEmpty {
                bucket = [m]
                curSender = m.senderUserId
                curOutgoing = m.isOutgoing
                lastMessageDate = m.date
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

            lastMessageDate = m.date
        }

        flushBucket()
        return rows
    }
}

// MARK: - Preference keys + helper views (macOS-safe scroll tracking)

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollOffsetReader: View {
    var body: some View {
        GeometryReader { geo in
            // In a named coordinate space, this minY moves with scroll.
            Color.clear
                .preference(key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named(MessagesPane.scrollSpaceName)).minY)
        }
    }
}

// MARK: - Day header + time separator

private struct DayHeaderView: View {
    let day: Date

    var body: some View {
        Text(dayLabel(day))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(.clear)
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }

        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}

private struct TimeSeparatorView: View {
    let date: Date

    var body: some View {
        Text(timeLabel(date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }
}

struct MessageGroup: Identifiable, Hashable {
    let id: String
    let isOutgoing: Bool
    let senderUserId: Int64?
    let messages: [TGMessage]
}
