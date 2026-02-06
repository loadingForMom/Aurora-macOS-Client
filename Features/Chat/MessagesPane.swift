//
//  MessagesPane.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import Foundation

struct MessagesPane: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    @ObservedObject var viewModel: ChatMessagesViewModel
    @Binding var isPagingHistory: Bool

    @State private var rows: [Row] = []
    @State private var windowMessages: [TGMessage] = []
    @State private var rowBuildTask: Task<Void, Never>? = nil
    @State private var rowBuildToken = UUID()

    @State private var pagingEnabled: Bool = false
    @State private var pagingInFlight: Bool = false
    @State private var pendingRestoreAnchorMessageId: Int64? = nil
    @State private var paginationBaselineFirstMessageId: Int64? = nil
    @State private var lastPaginationAnchorMessageId: Int64? = nil

    @State private var isAtBottom: Bool = true
    @State private var newIncomingCount: Int = 0

    @State private var didInitialScrollToBottom: Bool = false

    @State private var revealTimeX: CGFloat = 0
    @State private var lastAutoScrollAnimatedAtNs: UInt64 = 0
    @State private var didCrossPaginationThreshold: Bool = false
    @State private var lastTopSentinelMinY: CGFloat = -.greatestFiniteMagnitude
    private let groupGap: Int = 5 * 60
    private let majorGap: Int = 60 * 60
    private let autoScrollAnimationCooldownNs: UInt64 = 220_000_000
    private let paginationTopThreshold: CGFloat = 260
    private let heavyEffectsCutoffMessages: Int = 700

    private static let rowBuildWorker = RowsBuildWorker()
    private let scrollSpaceName = "messages-scroll-space"

    private var topSentinelId: String { "top:\(chat.id)" }
    private var bottomSentinelId: String { "bottom:\(chat.id)" }
    private var optimizeBubbleEffects: Bool { windowMessages.count >= heavyEffectsCutoffMessages }

    private struct RowBuildResult: Sendable {
        let filteredMessages: [TGMessage]
        let rows: [Row]
    }

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

    private actor RowsBuildWorker {
        func build(
            chatId: Int64,
            messages: [TGMessage],
            previousMessages: [TGMessage],
            previousRows: [Row],
            groupGap: Int,
            majorGap: Int
        ) -> RowBuildResult {
            let filtered = messages.filter { $0.chatId == chatId }
            if let incremental = MessagesPane.buildRowsIncrementalIfPossible(
                chatId: chatId,
                previousMessages: previousMessages,
                newMessages: filtered,
                previousRows: previousRows,
                groupGap: groupGap,
                majorGap: majorGap
            ) {
                return RowBuildResult(filteredMessages: filtered, rows: incremental)
            }
            let rebuilt = MessagesPane.buildRows(
                chatId: chatId,
                messages: filtered,
                groupGap: groupGap,
                majorGap: majorGap
            )
            return RowBuildResult(filteredMessages: filtered, rows: rebuilt)
        }
    }

    nonisolated private static func buildRows(
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

    nonisolated private static func buildRowsIncrementalIfPossible(
        chatId: Int64,
        previousMessages: [TGMessage],
        newMessages: [TGMessage],
        previousRows: [Row],
        groupGap: Int,
        majorGap: Int
    ) -> [Row]? {
        guard !previousMessages.isEmpty else { return nil }
        guard newMessages.count >= previousMessages.count else { return nil }
        guard newMessages.starts(with: previousMessages) else { return nil }
        let appendedMessages = Array(newMessages.dropFirst(previousMessages.count))
        guard !appendedMessages.isEmpty else { return previousRows }

        var rows = previousRows
        var lastMessage = previousMessages.last
        let calendar = Calendar.current

        for message in appendedMessages {
            appendMessageRow(
                chatId: chatId,
                message: message,
                rows: &rows,
                lastMessage: &lastMessage,
                calendar: calendar,
                groupGap: groupGap,
                majorGap: majorGap
            )
        }
        return rows
    }

    nonisolated private static func appendMessageRow(
        chatId: Int64,
        message: TGMessage,
        rows: inout [Row],
        lastMessage: inout TGMessage?,
        calendar: Calendar,
        groupGap: Int,
        majorGap: Int
    ) {
        let messageDate = Date(timeIntervalSince1970: TimeInterval(message.date))
        let messageDay = calendar.startOfDay(for: messageDate)

        if let previous = lastMessage {
            let previousDay = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(previous.date)))
            if previousDay != messageDay {
                let key = dayKey(messageDay, calendar: calendar)
                rows.append(.dayHeader(id: "\(chatId):day:\(key)", date: messageDay))
            } else if abs(message.date - previous.date) >= majorGap {
                rows.append(
                    .timeSeparator(
                        id: "\(chatId):time:\(message.date)",
                        date: messageDate
                    )
                )
            }
        } else {
            let key = dayKey(messageDay, calendar: calendar)
            rows.append(.dayHeader(id: "\(chatId):day:\(key)", date: messageDay))
        }

        if canAppendToLastGroup(
            rows: rows,
            previousMessage: lastMessage,
            message: message,
            groupGap: groupGap,
            calendar: calendar
        ) {
            if case .group(var group) = rows[rows.count - 1] {
                group.messages.append(message)
                rows[rows.count - 1] = .group(group)
                lastMessage = message
                return
            }
        }

        rows.append(
            .group(
                MessageGroup(
                    id: groupId(chatId: chatId, firstMessage: message),
                    isOutgoing: message.isOutgoing,
                    senderUserId: message.senderUserId,
                    messages: [message]
                )
            )
        )
        lastMessage = message
    }

    nonisolated private static func canAppendToLastGroup(
        rows: [Row],
        previousMessage: TGMessage?,
        message: TGMessage,
        groupGap: Int,
        calendar: Calendar
    ) -> Bool {
        guard let previousMessage else { return false }
        guard case .group(let group) = rows.last else { return false }
        guard group.messages.last?.id == previousMessage.id else { return false }
        let previousDay = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(previousMessage.date)))
        let messageDay = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(message.date)))
        guard previousDay == messageDay else { return false }
        let sameSender = message.senderUserId == group.senderUserId
        let sameDirection = message.isOutgoing == group.isOutgoing
        let close = abs(message.date - previousMessage.date) <= groupGap
        return sameSender && sameDirection && close
    }

    nonisolated private static func groupId(chatId: Int64, firstMessage: TGMessage) -> String {
        "\(chatId):g:\(firstMessage.chatId):\(firstMessage.id):\(firstMessage.localId?.uuidString ?? "nil")"
    }

    nonisolated private static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    @MainActor
    private func resetStateForChat() {
        rowBuildTask?.cancel()
        rowBuildTask = nil
        rowBuildToken = UUID()

        rows = []
        windowMessages = []

        pagingEnabled = false
        pagingInFlight = false
        isPagingHistory = false
        pendingRestoreAnchorMessageId = nil
        paginationBaselineFirstMessageId = nil
        lastPaginationAnchorMessageId = nil

        isAtBottom = true
        newIncomingCount = 0

        didInitialScrollToBottom = false

        revealTimeX = 0
        lastAutoScrollAnimatedAtNs = 0
        didCrossPaginationThreshold = false
        lastTopSentinelMinY = -.greatestFiniteMagnitude
    }

    @MainActor
    private func applyWindowMessages(_ messages: [TGMessage]) {
        let expectedChatId = chat.id
        let token = UUID()
        let previousMessages = windowMessages
        let previousRows = rows
        let currentGroupGap = groupGap
        let currentMajorGap = majorGap

        rowBuildToken = token
        rowBuildTask?.cancel()

        rowBuildTask = Task.detached(priority: .userInitiated) { [token, expectedChatId, messages, previousMessages, previousRows, currentGroupGap, currentMajorGap] in
            let buildResult = await Self.rowBuildWorker.build(
                chatId: expectedChatId,
                messages: messages,
                previousMessages: previousMessages,
                previousRows: previousRows,
                groupGap: currentGroupGap,
                majorGap: currentMajorGap
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard rowBuildToken == token else { return }
                guard chat.id == expectedChatId else { return }
                windowMessages = buildResult.filteredMessages
                rows = buildResult.rows
            }
        }
    }

    @MainActor
    private func requestOlderHistoryIfNeeded() -> Bool {
        guard didInitialScrollToBottom else { return false }
        guard pagingEnabled else { return false }
        guard !pagingInFlight else { return false }
        guard !store.isLoadingHistory else { return false }
        guard let anchorMessageId = windowMessages.first?.id, anchorMessageId > 0 else { return false }
        guard lastPaginationAnchorMessageId != anchorMessageId else { return false }

        lastPaginationAnchorMessageId = anchorMessageId
        pendingRestoreAnchorMessageId = anchorMessageId
        paginationBaselineFirstMessageId = anchorMessageId
        pagingInFlight = true
        isPagingHistory = true

        store.loadMoreHistory(chatId: chat.id, anchorMessageId: anchorMessageId)
        return true
    }

    @MainActor
    private func handleTopSentinelOffset(_ minY: CGFloat) {
        lastTopSentinelMinY = minY
        guard didInitialScrollToBottom else {
            didCrossPaginationThreshold = false
            return
        }
        let nearTop = minY >= -paginationTopThreshold
        if nearTop {
            guard !didCrossPaginationThreshold else { return }
            let started = requestOlderHistoryIfNeeded()
            didCrossPaginationThreshold = started
            return
        }
        didCrossPaginationThreshold = false
    }

    @MainActor
    private func clearPagingState() {
        pagingInFlight = false
        isPagingHistory = false
        pendingRestoreAnchorMessageId = nil
        paginationBaselineFirstMessageId = nil
        didCrossPaginationThreshold = false
    }

    private func scrollToBottomSentinel(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(bottomSentinelId, anchor: .bottom)
            }
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(bottomSentinelId, anchor: .bottom)
        }
    }

    private func scrollToMessageTop(_ proxy: ScrollViewProxy, messageId: Int64) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(messageId, anchor: .top)
        }
    }

    @MainActor
    private func handleWindowMessagesChange(
        oldMessages: [TGMessage],
        newMessages: [TGMessage],
        proxy: ScrollViewProxy
    ) {
        if pagingInFlight,
           let baseline = paginationBaselineFirstMessageId,
           let newFirstId = newMessages.first?.id,
           newFirstId != baseline {
            if let anchorId = pendingRestoreAnchorMessageId {
                scrollToMessageTop(proxy, messageId: anchorId)
            }
            clearPagingState()
            handleTopSentinelOffset(lastTopSentinelMinY)
        }

        if !didInitialScrollToBottom {
            guard !newMessages.isEmpty else { return }
            DispatchQueue.main.async {
                guard !didInitialScrollToBottom else { return }
                scrollToBottomSentinel(proxy, animated: false)
                didInitialScrollToBottom = true
                pagingEnabled = true
                isAtBottom = true
                newIncomingCount = 0
                handleTopSentinelOffset(lastTopSentinelMinY)
            }
            return
        }

        let oldLastId = oldMessages.last?.id
        let newLastId = newMessages.last?.id
        guard newLastId != oldLastId else { return }

        let firstChanged = oldMessages.first?.id != newMessages.first?.id
        let delta = max(1, abs(newMessages.count - oldMessages.count))

        if isAtBottom {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let isBulkMutation = firstChanged || delta > 2
            let shouldAnimate = !isBulkMutation
                && !store.isLoadingHistory
                && (nowNs &- lastAutoScrollAnimatedAtNs) >= autoScrollAnimationCooldownNs
            scrollToBottomSentinel(proxy, animated: shouldAnimate)
            if shouldAnimate {
                lastAutoScrollAnimatedAtNs = nowNs
            }
            newIncomingCount = 0
            return
        }

        guard let last = newMessages.last, !last.isOutgoing else { return }
        newIncomingCount += max(1, newMessages.count - oldMessages.count)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .dayHeader(_, let day):
            DayHeaderView(day: day)

        case .timeSeparator(_, let time):
            TimeSeparatorView(date: time)

        case .group(let group):
            ChatMessageGroupView(
                store: store,
                chat: chat,
                group: group,
                optimizeForLargeTimeline: optimizeBubbleEffects,
                revealTimeX: revealTimeX,
                jellyScrollImpulse: 0
            )
            .id(group.id)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Color.clear
                        .frame(height: 1)
                        .id(topSentinelId)
                        .onAppear {
                            Task { @MainActor in
                                _ = requestOlderHistoryIfNeeded()
                            }
                        }

                    ForEach(rows) { row in
                        rowView(row)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomSentinelId)
                        .onAppear {
                            isAtBottom = true
                            if newIncomingCount != 0 {
                                newIncomingCount = 0
                            }
                        }
                        .onDisappear {
                            isAtBottom = false
                        }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ContentMinYPreferenceKey.self,
                            value: geometry.frame(in: .named(scrollSpaceName)).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: scrollSpaceName)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .opacity((didInitialScrollToBottom || windowMessages.isEmpty) ? 1 : 0)
            .overlay(alignment: .bottomTrailing) {
                if newIncomingCount > 0 && !isAtBottom {
                    Button {
                        scrollToBottomSentinel(proxy, animated: true)
                        newIncomingCount = 0
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(newIncomingCount) new")
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
            .task(id: chat.id) {
                resetStateForChat()
                applyWindowMessages(viewModel.messages)
            }
            .onPreferenceChange(ContentMinYPreferenceKey.self) { minY in
                handleTopSentinelOffset(minY)
            }
            .onChange(of: viewModel.messages) { _, newMessages in
                applyWindowMessages(newMessages)
            }
            .onChange(of: windowMessages) { oldMessages, newMessages in
                handleWindowMessagesChange(
                    oldMessages: oldMessages,
                    newMessages: newMessages,
                    proxy: proxy
                )
            }
            .onChange(of: store.isLoadingHistory) { _, isLoading in
                guard !isLoading else { return }
                if pagingInFlight, windowMessages.first?.id == paginationBaselineFirstMessageId {
                    clearPagingState()
                }
                // Retry immediately if user is already near top and previous attempt was blocked.
                handleTopSentinelOffset(lastTopSentinelMinY)
            }
            .onDisappear {
                rowBuildTask?.cancel()
                rowBuildTask = nil
                isPagingHistory = false
            }
        }
        .id(chat.id)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private enum ChatFormatters {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
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

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return ChatFormatters.dayFormatter.string(from: date)
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
    var messages: [TGMessage]
}

private struct ContentMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = -.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
