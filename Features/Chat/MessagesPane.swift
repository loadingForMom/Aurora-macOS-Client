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
    @State private var showAfterInitialJump: Bool = false

    @State private var revealTimeX: CGFloat = 0
    @State private var revealGestureEngaged: Bool = false

    private let maxReveal: CGFloat = 72
    private let groupGap: Int = 5 * 60
    private let majorGap: Int = 60 * 60

    private static let rowBuildWorker = RowsBuildWorker()

    private var topSentinelId: String { "top:\(chat.id)" }
    private var bottomSentinelId: String { "bottom:\(chat.id)" }

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
            groupGap: Int,
            majorGap: Int
        ) -> [Row] {
            MessagesPane.buildRows(
                chatId: chatId,
                messages: messages,
                groupGap: groupGap,
                majorGap: majorGap
            )
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
        pendingRestoreAnchorMessageId = nil
        paginationBaselineFirstMessageId = nil
        lastPaginationAnchorMessageId = nil

        isAtBottom = true
        newIncomingCount = 0

        didInitialScrollToBottom = false
        showAfterInitialJump = false

        revealTimeX = 0
        revealGestureEngaged = false
    }

    @MainActor
    private func applyWindowMessages(_ messages: [TGMessage]) {
        let expectedChatId = chat.id
        let token = UUID()

        rowBuildToken = token
        rowBuildTask?.cancel()

        rowBuildTask = Task(priority: .userInitiated) { [token, expectedChatId, messages] in
            let filtered = messages.filter { $0.chatId == expectedChatId }
            let builtRows = await Self.rowBuildWorker.build(
                chatId: expectedChatId,
                messages: filtered,
                groupGap: groupGap,
                majorGap: majorGap
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard rowBuildToken == token else { return }
                guard chat.id == expectedChatId else { return }
                windowMessages = filtered
                rows = builtRows
            }
        }
    }

    @MainActor
    private func requestOlderHistoryIfNeeded() {
        guard pagingEnabled else { return }
        guard !pagingInFlight else { return }
        guard !store.isLoadingHistory else { return }
        guard let anchorMessageId = windowMessages.first?.id, anchorMessageId > 0 else { return }
        guard lastPaginationAnchorMessageId != anchorMessageId else { return }

        lastPaginationAnchorMessageId = anchorMessageId
        pendingRestoreAnchorMessageId = anchorMessageId
        paginationBaselineFirstMessageId = anchorMessageId
        pagingInFlight = true

        viewModel.loadOlder(pageSize: 80)
        store.loadMoreHistory(chatId: chat.id, anchorMessageId: anchorMessageId)
    }

    @MainActor
    private func clearPagingState() {
        pagingInFlight = false
        pendingRestoreAnchorMessageId = nil
        paginationBaselineFirstMessageId = nil
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
    private func performInitialJumpIfNeeded(_ proxy: ScrollViewProxy) {
        guard !didInitialScrollToBottom else { return }

        DispatchQueue.main.async {
            guard !didInitialScrollToBottom else { return }
            scrollToBottomSentinel(proxy, animated: false)
            didInitialScrollToBottom = true
            pagingEnabled = true
            isAtBottom = true
            newIncomingCount = 0
            showAfterInitialJump = true
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
        }

        guard didInitialScrollToBottom else { return }

        let oldLastId = oldMessages.last?.id
        let newLastId = newMessages.last?.id
        guard newLastId != oldLastId else { return }

        if isAtBottom {
            scrollToBottomSentinel(proxy, animated: true)
            newIncomingCount = 0
            return
        }

        guard let last = newMessages.last, !last.isOutgoing else { return }
        let delta = max(1, newMessages.count - oldMessages.count)
        newIncomingCount += delta
    }

    private var revealGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height

                if !revealGestureEngaged {
                    guard abs(dx) > abs(dy) * 1.25 else { return }
                    revealGestureEngaged = true
                }

                revealTimeX = min(maxReveal, max(0, -dx))
            }
            .onEnded { _ in
                revealGestureEngaged = false
                withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.72, blendDuration: 0.10)) {
                    revealTimeX = 0
                }
            }
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
                            requestOlderHistoryIfNeeded()
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
            }
            .opacity(showAfterInitialJump ? 1 : 0)
            .allowsHitTesting(showAfterInitialJump)
            .animation(nil, value: showAfterInitialJump)
            .simultaneousGesture(revealGesture)
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
                await Task.yield()
                performInitialJumpIfNeeded(proxy)
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
                guard !isLoading, pagingInFlight else { return }
                if windowMessages.first?.id == paginationBaselineFirstMessageId {
                    clearPagingState()
                }
            }
            .onDisappear {
                rowBuildTask?.cancel()
                rowBuildTask = nil
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
    let messages: [TGMessage]
}
