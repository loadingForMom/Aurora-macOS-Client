//
//  MessagesPane.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import Foundation
import AppKit
import OSLog

struct MessagesPane: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    @ObservedObject var viewModel: ChatMessagesViewModel
    @Binding var isPagingHistory: Bool

    @State private var rows: [Row] = []
    @State private var windowMessages: [TGMessage] = []
    @State private var previousMessageIds: [Int64] = []
    @State private var groupRowMinYById: [String: CGFloat] = [:]
    @State private var prependAnchorMessageId: Int64? = nil
    @State private var prependAnchorRowId: String? = nil
    @State private var prependAnchorMinYBefore: CGFloat? = nil
    @State private var rowBuildTask: Task<Void, Never>? = nil
    @State private var rowBuildToken = UUID()
    @State private var scrollViewRef = ScrollViewReference()

    @State private var pagingEnabled: Bool = false
    @State private var pagingInFlight: Bool = false
    @State private var restoreAnchorAfterPaging: Bool = false
    @State private var pendingRestoreAnchorMessageId: Int64? = nil
    @State private var paginationBaselineFirstMessageId: Int64? = nil
    @State private var lastRequestedTopAnchorMessageId: Int64? = nil

    @State private var isAtBottom: Bool = true
    @State private var newIncomingCount: Int = 0
    @State private var visibleMessageIds: Set<Int64> = []
    @State private var visibleReportTask: Task<Void, Never>? = nil

    @State private var didInitialScrollToBottom: Bool = false

    @State private var revealTimeX: CGFloat = 0
    @State private var lastAutoScrollAnimatedAtNs: UInt64 = 0
    @State private var didCrossPaginationThreshold: Bool = false
    @State private var lastTopSentinelMinY: CGFloat = -.greatestFiniteMagnitude
    @State private var isTopSentinelVisible: Bool = false
    @State private var pendingTopVisibleRetryAfterLoading: Bool = false
    @State private var isLiveScrolling: Bool = false
    @State private var isLightweightScrollRenderMode: Bool = false
    @State private var lightweightScrollRenderModeResetTask: Task<Void, Never>? = nil
    @State private var windowingDebugTask: Task<Void, Never>? = nil
    @State private var windowFocusSyncTask: Task<Void, Never>? = nil
    private let groupGap: Int = 5 * 60
    private let majorGap: Int = 60 * 60
    private let autoScrollAnimationCooldownNs: UInt64 = 220_000_000
    private let lightweightRenderModeResetDelayNs: UInt64 = 120_000_000
    private let paginationTopThreshold: CGFloat = 260
    private let heavyEffectsCutoffMessages: Int = 700
    private let textPrewarmBudget: Int = 150
    private let revealTimeMaxX: CGFloat = 72
    private let windowingDebugIntervalNs: UInt64 = 2_000_000_000
    private let windowFocusSyncDelayNs: UInt64 = 120_000_000

    private static let rowBuildWorker = RowsBuildWorker()
    private let scrollSpaceName = "messages-scroll-space"
    private let windowingLog = Logger(subsystem: "com.aurora.app", category: "chat.windowing")

    private var topSentinelId: String { "top:\(chat.id)" }
    private var bottomSentinelId: String { "bottom:\(chat.id)" }
    private var optimizeBubbleEffects: Bool { windowMessages.count >= heavyEffectsCutoffMessages }
    private var optimizeBubbleEffectsNow: Bool { optimizeBubbleEffects || isLiveScrolling }
    private var isViewportUnderfilledForPaging: Bool {
        didInitialScrollToBottom &&
        isTopSentinelVisible &&
        isAtBottom &&
        !windowMessages.isEmpty
    }
    private var showTopHistoryLoader: Bool {
        (pagingInFlight || store.isLoadingHistory) &&
        (isTopSentinelVisible || isViewportUnderfilledForPaging)
    }

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
            let traceEnabled = ChatPerfTrace.isEnabled(for: chatId)
            let buildStartNs = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0
            let signpostId = ChatPerfTrace.beginSignpost("buildRows", chatId: chatId)
            defer {
                ChatPerfTrace.endSignpost("buildRows", signpostId: signpostId, chatId: chatId)
            }

            let filtered = messages.filter { $0.chatId == chatId }
            if let incremental = MessagesPane.buildRowsIncrementalIfPossible(
                chatId: chatId,
                previousMessages: previousMessages,
                newMessages: filtered,
                previousRows: previousRows,
                groupGap: groupGap,
                majorGap: majorGap
            ) {
                if traceEnabled {
                    let buildRowsDurationMs = ChatPerfTrace.elapsedMs(since: buildStartNs)
                    ChatPerfTrace.recordRowsBuild(
                        chatId: chatId,
                        isIncremental: true,
                        durationMs: buildRowsDurationMs
                    )
                }
                return RowBuildResult(filteredMessages: filtered, rows: incremental)
            }
            let rebuilt = MessagesPane.buildRows(
                chatId: chatId,
                messages: filtered,
                groupGap: groupGap,
                majorGap: majorGap
            )
            if traceEnabled {
                let buildRowsDurationMs = ChatPerfTrace.elapsedMs(since: buildStartNs)
                ChatPerfTrace.recordRowsBuild(
                    chatId: chatId,
                    isIncremental: false,
                    durationMs: buildRowsDurationMs
                )
            }
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

    nonisolated private static func textPrewarmSlice(
        messages: [TGMessage],
        visibleMessageIds: Set<Int64>,
        fallbackAnchorMessageId: Int64?,
        budget: Int
    ) -> [TGMessage] {
        guard !messages.isEmpty else { return [] }
        let clampedBudget = max(1, min(budget, messages.count))

        var indexById: [Int64: Int] = [:]
        indexById.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            indexById[message.id] = index
        }

        let anchorIndex: Int = {
            if !visibleMessageIds.isEmpty {
                var visibleIndices: [Int] = []
                visibleIndices.reserveCapacity(visibleMessageIds.count)
                for id in visibleMessageIds {
                    if let index = indexById[id] {
                        visibleIndices.append(index)
                    }
                }
                if !visibleIndices.isEmpty {
                    visibleIndices.sort()
                    return visibleIndices[visibleIndices.count / 2]
                }
            }
            if let fallbackAnchorMessageId,
               let fallbackIndex = indexById[fallbackAnchorMessageId] {
                return fallbackIndex
            }
            return messages.count - 1
        }()

        let halfWindow = clampedBudget / 2
        var lowerBound = max(0, anchorIndex - halfWindow)
        let upperBound = min(messages.count, lowerBound + clampedBudget)
        if upperBound - lowerBound < clampedBudget {
            lowerBound = max(0, upperBound - clampedBudget)
        }
        guard lowerBound < upperBound else { return [] }

        return messages[lowerBound..<upperBound].filter { message in
            message.textForRendering != nil || !message.entities.isEmpty
        }
    }

    @MainActor
    private func scheduleTextPrewarm(messages: [TGMessage]) {
        let candidates = Self.textPrewarmSlice(
            messages: messages,
            visibleMessageIds: visibleMessageIds,
            fallbackAnchorMessageId: pendingRestoreAnchorMessageId,
            budget: textPrewarmBudget
        )
        guard !candidates.isEmpty else { return }
        MessageTextPipeline.enqueuePrewarm(chatId: chat.id, messages: candidates, style: .bubbleBody)
    }

    nonisolated private static func updatedMessagesByIdForContentOnlyUpdate(
        previousMessages: [TGMessage],
        newMessages: [TGMessage]
    ) -> [Int64: TGMessage]? {
        guard previousMessages.count == newMessages.count else { return nil }
        var updatedById: [Int64: TGMessage] = [:]
        updatedById.reserveCapacity(min(8, previousMessages.count))

        for index in previousMessages.indices {
            let oldMessage = previousMessages[index]
            let newMessage = newMessages[index]
            guard oldMessage.id == newMessage.id else { return nil }
            if oldMessage == newMessage {
                continue
            }
            updatedById[newMessage.id] = newMessage
        }
        return updatedById
    }

    nonisolated private static func patchRowsForUpdatedMessages(
        previousRows: [Row],
        updatedMessagesById: [Int64: TGMessage]
    ) -> [Row] {
        guard !updatedMessagesById.isEmpty else { return previousRows }
        var patchedRows: [Row] = []
        patchedRows.reserveCapacity(previousRows.count)

        for row in previousRows {
            switch row {
            case .group(var group):
                var groupUpdated = false
                for index in group.messages.indices {
                    let messageId = group.messages[index].id
                    guard let updatedMessage = updatedMessagesById[messageId] else { continue }
                    guard group.messages[index] != updatedMessage else { continue }
                    group.messages[index] = updatedMessage
                    groupUpdated = true
                }
                patchedRows.append(groupUpdated ? .group(group) : row)
            case .dayHeader, .timeSeparator:
                patchedRows.append(row)
            }
        }
        return patchedRows
    }

    nonisolated private static func rowIdContainingMessage(
        _ messageId: Int64,
        rows: [Row]
    ) -> String? {
        for row in rows {
            guard case .group(let group) = row else { continue }
            if group.messages.contains(where: { $0.id == messageId }) {
                return group.id
            }
        }
        return nil
    }

    @MainActor
    private func preparePrependPixelAnchor(messageId: Int64) {
        prependAnchorMessageId = messageId
        let rowId = Self.rowIdContainingMessage(messageId, rows: rows)
        prependAnchorRowId = rowId
        prependAnchorMinYBefore = rowId.flatMap { groupRowMinYById[$0] }
    }

    @MainActor
    private func topVisibleMessageIdForPrependAnchor() -> Int64? {
        guard !visibleMessageIds.isEmpty else { return nil }
        for message in windowMessages where message.id > 0 {
            if visibleMessageIds.contains(message.id) {
                return message.id
            }
        }
        return nil
    }

    @MainActor
    private func clearPrependPixelAnchor() {
        prependAnchorMessageId = nil
        prependAnchorRowId = nil
        prependAnchorMinYBefore = nil
    }

    @MainActor
    private func hasPrependPixelMeasurement(anchorMessageId: Int64) -> Bool {
        guard prependAnchorMessageId == anchorMessageId else { return false }
        guard prependAnchorMinYBefore != nil else { return false }
        guard let currentRowId = Self.rowIdContainingMessage(anchorMessageId, rows: rows) else { return false }
        return groupRowMinYById[currentRowId] != nil
    }

    @MainActor
    private func restorePrependPixelOffsetIfPossible(anchorMessageId: Int64) -> Bool {
        guard prependAnchorMessageId == anchorMessageId else { return false }
        guard let beforeMinY = prependAnchorMinYBefore else { return false }
        guard let currentRowId = Self.rowIdContainingMessage(anchorMessageId, rows: rows) else { return false }
        guard let afterMinY = groupRowMinYById[currentRowId] else { return false }
        guard let scrollView = scrollViewRef.scrollView else { return false }

        let deltaY = afterMinY - beforeMinY
        guard abs(deltaY) > 0.5 else { return true }

        let clipView = scrollView.contentView
        var newOrigin = clipView.bounds.origin
        newOrigin.y += deltaY
        if let documentView = scrollView.documentView {
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            newOrigin.y = min(max(0, newOrigin.y), maxY)
        }
        clipView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    @MainActor
    private func resetStateForChat() {
        rowBuildTask?.cancel()
        rowBuildTask = nil
        rowBuildToken = UUID()
        stopWindowingDebugLogging(reason: "reset")
        cancelWindowFocusSyncTask()

        rows = []
        windowMessages = []
        previousMessageIds = []
        groupRowMinYById = [:]
        clearPrependPixelAnchor()

        pagingEnabled = false
        pagingInFlight = false
        restoreAnchorAfterPaging = false
        isPagingHistory = false
        pendingRestoreAnchorMessageId = nil
        paginationBaselineFirstMessageId = nil
        lastRequestedTopAnchorMessageId = nil

        isAtBottom = true
        newIncomingCount = 0
        visibleReportTask?.cancel()
        visibleReportTask = nil
        visibleMessageIds = []
        store.resetVisibleMessageTracking(chatId: chat.id)
        store.updateMessageWindowFocus(chatId: chat.id, isFollowingLatest: true, anchorMessageId: nil)

        didInitialScrollToBottom = false

        revealTimeX = 0
        lastAutoScrollAnimatedAtNs = 0
        didCrossPaginationThreshold = false
        lastTopSentinelMinY = -.greatestFiniteMagnitude
        isTopSentinelVisible = false
        pendingTopVisibleRetryAfterLoading = false
        lightweightScrollRenderModeResetTask?.cancel()
        lightweightScrollRenderModeResetTask = nil
        isLightweightScrollRenderMode = false
    }

    @MainActor
    private func applyWindowMessages(_ messages: [TGMessage]) {
        let expectedChatId = chat.id
        let traceEnabled = ChatPerfTrace.isEnabled(for: expectedChatId)
        let applyWindowStartNs = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let applySignpostId = ChatPerfTrace.beginSignpost("applyWindowMessages", chatId: expectedChatId)
        let filteredMessages = messages.filter { $0.chatId == expectedChatId }
        let currentIds = filteredMessages.map(\.id)
        let token = UUID()
        let previousMessages = windowMessages
        let previousRows = rows
        let currentGroupGap = groupGap
        let currentMajorGap = majorGap

        rowBuildToken = token
        rowBuildTask?.cancel()
        rowBuildTask = nil

        if previousMessageIds.elementsEqual(currentIds) {
            let updatedMessagesById = Self.updatedMessagesByIdForContentOnlyUpdate(
                previousMessages: previousMessages,
                newMessages: filteredMessages
            ) ?? [:]
            if !updatedMessagesById.isEmpty {
                rows = Self.patchRowsForUpdatedMessages(previousRows: previousRows, updatedMessagesById: updatedMessagesById)
            }
            windowMessages = filteredMessages
            previousMessageIds = currentIds
            if traceEnabled {
                ChatPerfTrace.recordContentOnlyFastPath(chatId: expectedChatId)
            }
            if traceEnabled {
                let applyWindowMessagesDurationMs = ChatPerfTrace.elapsedMs(since: applyWindowStartNs)
                ChatPerfTrace.recordApplyWindowMessages(chatId: expectedChatId, durationMs: applyWindowMessagesDurationMs)
            }
            ChatPerfTrace.endSignpost("applyWindowMessages", signpostId: applySignpostId, chatId: expectedChatId)
            return
        }

        rowBuildTask = Task.detached(priority: .userInitiated) { [token, expectedChatId, messages, previousMessages, previousRows, currentGroupGap, currentMajorGap, traceEnabled, applyWindowStartNs, applySignpostId] in
            defer {
                if traceEnabled {
                    let applyWindowMessagesDurationMs = ChatPerfTrace.elapsedMs(since: applyWindowStartNs)
                    ChatPerfTrace.recordApplyWindowMessages(chatId: expectedChatId, durationMs: applyWindowMessagesDurationMs)
                }
                ChatPerfTrace.endSignpost("applyWindowMessages", signpostId: applySignpostId, chatId: expectedChatId)
            }

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
                previousMessageIds = buildResult.filteredMessages.map(\.id)
            }
        }
    }

    @MainActor
    private func requestOlderHistoryIfNeeded() -> Bool {
        guard didInitialScrollToBottom else {
            tracePagingSkip(skipReason: "cooldown", anchorMessageId: windowMessages.first?.id)
            return false
        }
        guard pagingEnabled else {
            tracePagingSkip(skipReason: "cooldown", anchorMessageId: windowMessages.first?.id)
            return false
        }
        guard !pagingInFlight else {
            tracePagingSkip(skipReason: "inFlight", anchorMessageId: windowMessages.first?.id)
            return false
        }
        guard !store.isLoadingHistory else {
            tracePagingSkip(skipReason: "inFlight", anchorMessageId: windowMessages.first?.id)
            return false
        }
        let paginationState = store.historyPaginationState(chatId: chat.id)
        guard paginationState.canLoadMore else {
            tracePagingSkip(skipReason: "endReached", anchorMessageId: windowMessages.first?.id)
            return false
        }
        guard !paginationState.isLoadingMore else {
            tracePagingSkip(skipReason: "inFlight", anchorMessageId: windowMessages.first?.id)
            return false
        }
        guard let anchorMessageId = windowMessages.first?.id, anchorMessageId > 0 else {
            tracePagingSkip(skipReason: "noAnchor", anchorMessageId: windowMessages.first?.id)
            return false
        }
        if lastRequestedTopAnchorMessageId == anchorMessageId {
            tracePagingSkip(skipReason: "cooldown", anchorMessageId: anchorMessageId)
            return false
        }

        let uiTopMessageId = windowMessages.first?.id
        let started = store.loadMoreHistory(
            chatId: chat.id,
            anchorMessageId: anchorMessageId,
            uiTopMessageId: uiTopMessageId,
            uiTopKind: topElementKindForHistoryTrace(),
            storeMinIdVisible: uiTopMessageId,
            anchorSource: .uiTop
        )
        guard started else {
            tracePagingSkip(skipReason: "storeRejected", anchorMessageId: anchorMessageId)
            return false
        }

        let pixelAnchorMessageId =
            pendingRestoreAnchorMessageId ??
            prependAnchorMessageId ??
            topVisibleMessageIdForPrependAnchor() ??
            anchorMessageId

        preparePrependPixelAnchor(messageId: pixelAnchorMessageId)
        pendingRestoreAnchorMessageId = pixelAnchorMessageId
        paginationBaselineFirstMessageId = anchorMessageId
        lastRequestedTopAnchorMessageId = anchorMessageId
        store.updateMessageWindowFocus(
            chatId: chat.id,
            isFollowingLatest: false,
            anchorMessageId: pixelAnchorMessageId
        )
        // Keep viewport stable while prepending older messages.
        restoreAnchorAfterPaging = true
        pagingInFlight = true
        isPagingHistory = true
        return true
    }

    private func topElementKindForHistoryTrace() -> String? {
        guard let first = rows.first else { return nil }
        switch first {
        case .group:
            if let topMessageId = windowMessages.first?.id, topMessageId <= 0 {
                return "placeholder"
            }
            return "message"
        case .dayHeader, .timeSeparator:
            return "separator"
        }
    }

    @MainActor
    private func tracePagingSkip(skipReason: String, anchorMessageId: Int64?) {
        guard HistoryTrace.isEnabled(for: chat.id) else { return }
        HistoryTrace.emit(
            tag: "HIST_SKIP",
            chatId: chat.id,
            fields: [
                ("reason", "older"),
                ("skipReason", skipReason),
                ("anchorMessageId", HistoryTrace.optionalInt64(anchorMessageId)),
                ("didInitialScrollToBottom", HistoryTrace.boolValue(didInitialScrollToBottom)),
                ("pagingEnabled", HistoryTrace.boolValue(pagingEnabled)),
                ("pagingInFlight", HistoryTrace.boolValue(pagingInFlight)),
                ("storeLoadingHistory", HistoryTrace.boolValue(store.isLoadingHistory)),
                ("paginationBaselineFirstMessageId", HistoryTrace.optionalInt64(paginationBaselineFirstMessageId)),
                ("uiTopMessageId", HistoryTrace.optionalInt64(windowMessages.first?.id)),
                ("uiTopKind", topElementKindForHistoryTrace() ?? "null"),
                ("isAtBottom", HistoryTrace.boolValue(isAtBottom))
            ],
            rateKey: "ui:\(chat.id):\(skipReason)",
            rateLimitMs: 500
        )
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
            didCrossPaginationThreshold = true
            requestOlderHistoryFromTopTrigger(source: "nearTopThreshold")
            return
        }

        didCrossPaginationThreshold = false
    }

    @MainActor
    private func requestOlderHistoryFromTopTrigger(source: String) {
        if HistoryTrace.isEnabled(for: chat.id) {
            HistoryTrace.emit(
                tag: "HIST_UI",
                chatId: chat.id,
                fields: [
                    ("event", "requestOlderTrigger"),
                    ("source", source),
                    ("isTopSentinelVisible", HistoryTrace.boolValue(isTopSentinelVisible)),
                    ("isAtBottom", HistoryTrace.boolValue(isAtBottom)),
                    ("isViewportUnderfilled", HistoryTrace.boolValue(isViewportUnderfilledForPaging)),
                    ("pagingInFlight", HistoryTrace.boolValue(pagingInFlight)),
                    ("storeLoadingHistory", HistoryTrace.boolValue(store.isLoadingHistory)),
                    ("uiTopMessageId", HistoryTrace.optionalInt64(windowMessages.first?.id))
                ],
                rateKey: "ui:\(chat.id):trigger:\(source)",
                rateLimitMs: 120
            )
        }

        let started = requestOlderHistoryIfNeeded()
        if started {
            pendingTopVisibleRetryAfterLoading = false
            return
        }
        if isTopSentinelVisible && didInitialScrollToBottom && store.isLoadingHistory {
            pendingTopVisibleRetryAfterLoading = true
        }
    }

    @MainActor
    private func maybeRequestOlderForUnderfilledViewport(source: String) {
        guard isViewportUnderfilledForPaging else { return }
        guard !pagingInFlight else { return }

        if store.isLoadingHistory {
            pendingTopVisibleRetryAfterLoading = true
            return
        }
        requestOlderHistoryFromTopTrigger(source: source)
    }

    @MainActor
    private func clearPagingState() {
        pagingInFlight = false
        restoreAnchorAfterPaging = false
        isPagingHistory = false
        pendingRestoreAnchorMessageId = nil
        paginationBaselineFirstMessageId = nil
    }

    @MainActor
    private func handleMessageVisibilityChange(messageId: Int64, isVisible: Bool) {
        guard messageId > 0 else { return }
        if isVisible {
            let inserted = visibleMessageIds.insert(messageId).inserted
            guard inserted else { return }
        } else {
            guard visibleMessageIds.remove(messageId) != nil else { return }
        }
        scheduleVisibleMessagesReport()
        scheduleWindowFocusSync()
    }

    @MainActor
    private func pruneVisibleMessageIdsToWindow() {
        let validIds = Set(windowMessages.filter { $0.id > 0 }.map(\.id))
        let pruned = visibleMessageIds.intersection(validIds)
        guard pruned != visibleMessageIds else { return }
        visibleMessageIds = pruned
        scheduleVisibleMessagesReport()
        scheduleWindowFocusSync()
    }

    @MainActor
    private func scheduleVisibleMessagesReport() {
        visibleReportTask?.cancel()

        let chatId = chat.id
        let ids = Array(visibleMessageIds).sorted()
        guard !ids.isEmpty else {
            store.resetVisibleMessageTracking(chatId: chatId)
            return
        }

        visibleReportTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            let currentIds = Array(visibleMessageIds).sorted()
            guard !currentIds.isEmpty else {
                store.resetVisibleMessageTracking(chatId: chatId)
                return
            }

            store.reportVisibleMessages(
                chatId: chatId,
                minMessageId: currentIds.first,
                maxMessageId: currentIds.last,
                messageIds: currentIds
            )
        }
    }

    @MainActor
    private func anchorMessageIdForWindowFocus() -> Int64? {
        if let pendingRestoreAnchorMessageId, pendingRestoreAnchorMessageId > 0 {
            return pendingRestoreAnchorMessageId
        }

        let visibleInOrder = windowMessages.compactMap { message -> Int64? in
            guard message.id > 0 else { return nil }
            guard visibleMessageIds.contains(message.id) else { return nil }
            return message.id
        }
        if !visibleInOrder.isEmpty {
            return visibleInOrder[visibleInOrder.count / 2]
        }

        if let topVisible = topVisibleMessageIdForPrependAnchor(), topVisible > 0 {
            return topVisible
        }
        return windowMessages.last(where: { $0.id > 0 })?.id
    }

    @MainActor
    private func cancelWindowFocusSyncTask() {
        windowFocusSyncTask?.cancel()
        windowFocusSyncTask = nil
    }

    @MainActor
    private func scheduleWindowFocusSync() {
        cancelWindowFocusSyncTask()

        let chatId = chat.id
        let isFollowingLatest = isAtBottom
        let anchorMessageId = isFollowingLatest ? nil : anchorMessageIdForWindowFocus()
        windowFocusSyncTask = Task { @MainActor [chatId, isFollowingLatest, anchorMessageId] in
            try? await Task.sleep(nanoseconds: windowFocusSyncDelayNs)
            guard !Task.isCancelled else { return }
            store.updateMessageWindowFocus(
                chatId: chatId,
                isFollowingLatest: isFollowingLatest,
                anchorMessageId: anchorMessageId
            )
            windowFocusSyncTask = nil
        }
    }

    @MainActor
    private func updateLightweightScrollRenderMode(isScrolling: Bool) {
        if isScrolling {
            lightweightScrollRenderModeResetTask?.cancel()
            lightweightScrollRenderModeResetTask = nil
            if !isLightweightScrollRenderMode {
                isLightweightScrollRenderMode = true
            }
            return
        }

        lightweightScrollRenderModeResetTask?.cancel()
        lightweightScrollRenderModeResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: lightweightRenderModeResetDelayNs)
            guard !Task.isCancelled else { return }
            guard !isLiveScrolling else { return }
            isLightweightScrollRenderMode = false
            lightweightScrollRenderModeResetTask = nil
        }
    }

    @MainActor
    private func startWindowingDebugLogging() {
#if DEBUG
        stopWindowingDebugLogging()
        let chatId = chat.id
        windowingDebugTask = Task { @MainActor [chatId] in
            await emitWindowingDebugLog(reason: "start", chatId: chatId)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: windowingDebugIntervalNs)
                guard !Task.isCancelled else { return }
                await emitWindowingDebugLog(reason: "tick", chatId: chatId)
            }
        }
#endif
    }

    @MainActor
    private func stopWindowingDebugLogging(reason: String = "stop") {
#if DEBUG
        guard windowingDebugTask != nil else { return }
        Task { @MainActor in
            await emitWindowingDebugLog(reason: reason, chatId: chat.id)
        }
        windowingDebugTask?.cancel()
        windowingDebugTask = nil
#else
        _ = reason
#endif
    }

    @MainActor
    private func emitWindowingDebugLog(reason: String, chatId: Int64) async {
#if DEBUG
        let uiRowsCount = rows.count
        let uiMessagesCount = windowMessages.count
        let visibleCount = visibleMessageIds.count
        let snapshot = await store.messageStore.debugWindowSnapshot(chatId: chatId)
        windowingLog.debug(
            "chat window metrics chatId=\(chatId, privacy: .public) reason=\(reason, privacy: .public) isLiveScrolling=\(isLiveScrolling, privacy: .public) windowLimit=\(snapshot.windowLimit, privacy: .public) storeWindowCount=\(snapshot.orderedCount, privacy: .public) storeModelsCount=\(snapshot.modelsCount, privacy: .public) uiRowsCount=\(uiRowsCount, privacy: .public) uiMessagesCount=\(uiMessagesCount, privacy: .public) visibleCount=\(visibleCount, privacy: .public) storeVisibleCount=\(snapshot.visibleCount, privacy: .public)"
        )
#else
        _ = reason
        _ = chatId
#endif
    }

    @MainActor
    private func handleTimeRevealDragChanged(_ value: DragGesture.Value) {
        let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.15
        guard horizontal else { return }
        let reveal = min(revealTimeMaxX, max(0, -value.translation.width))
        if abs(reveal - revealTimeX) > 0.5 {
            revealTimeX = reveal
        }
    }

    @MainActor
    private func handleTimeRevealDragEnded() {
        guard revealTimeX > 0 else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            revealTimeX = 0
        }
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
            if restoreAnchorAfterPaging, let anchorId = pendingRestoreAnchorMessageId {
                if restorePrependPixelOffsetIfPossible(anchorMessageId: anchorId) {
                    clearPrependPixelAnchor()
                } else {
                    DispatchQueue.main.async {
                        if !restorePrependPixelOffsetIfPossible(anchorMessageId: anchorId) {
                            if !hasPrependPixelMeasurement(anchorMessageId: anchorId) {
                                scrollToMessageTop(proxy, messageId: anchorId)
                            }
                        }
                        clearPrependPixelAnchor()
                    }
                }
            } else {
                clearPrependPixelAnchor()
            }
            lastRequestedTopAnchorMessageId = nil
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
                maybeRequestOlderForUnderfilledViewport(source: "initialScrollToBottom")
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
            maybeRequestOlderForUnderfilledViewport(source: "atBottomMutation")
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
                optimizeForLargeTimeline: optimizeBubbleEffectsNow,
                isScrolling: isLightweightScrollRenderMode,
                revealTimeX: revealTimeX,
                jellyScrollImpulse: 0,
                onMessageAppear: { messageId in
                    handleMessageVisibilityChange(messageId: messageId, isVisible: true)
                },
                onMessageDisappear: { messageId in
                    handleMessageVisibilityChange(messageId: messageId, isVisible: false)
                }
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
                            isTopSentinelVisible = true
                            maybeRequestOlderForUnderfilledViewport(source: "topSentinelVisible")
                        }
                        .onDisappear {
                            isTopSentinelVisible = false
                            pendingTopVisibleRetryAfterLoading = false
                        }

                    if showTopHistoryLoader {
                        HStack {
                            Spacer(minLength: 0)
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(.circular)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }

                    ForEach(rows) { row in
                        rowView(row)
                            .background {
                                switch row {
                                case .group:
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: GroupRowMinYPreferenceKey.self,
                                            value: [row.id: geometry.frame(in: .named(scrollSpaceName)).minY]
                                        )
                                    }
                                case .dayHeader, .timeSeparator:
                                    Color.clear
                                }
                            }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomSentinelId)
                        .onAppear {
                            isAtBottom = true
                            if newIncomingCount != 0 {
                                newIncomingCount = 0
                            }
                            maybeRequestOlderForUnderfilledViewport(source: "bottomSentinelVisible")
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
            .background(
                ScrollLiveStateObserver(
                    isLiveScrolling: $isLiveScrolling,
                    onResolveScrollView: { scrollView in
                        scrollViewRef.scrollView = scrollView
                    }
                )
                    .frame(width: 0, height: 0)
            )
            .transaction { transaction in
                if isLiveScrolling {
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            }
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        handleTimeRevealDragChanged(value)
                    }
                    .onEnded { _ in
                        handleTimeRevealDragEnded()
                    }
            )
            .task(id: chat.id) {
                resetStateForChat()
                ChatPerfTrace.recordScrollState(chatId: chat.id, isScrolling: isLiveScrolling)
                updateLightweightScrollRenderMode(isScrolling: isLiveScrolling)
                startWindowingDebugLogging()
                applyWindowMessages(viewModel.messages)
            }
            .onPreferenceChange(ContentMinYPreferenceKey.self) { minY in
                handleTopSentinelOffset(minY)
                maybeRequestOlderForUnderfilledViewport(source: "contentOffsetChanged")
            }
            .onPreferenceChange(GroupRowMinYPreferenceKey.self) { map in
                groupRowMinYById = map
            }
            .onChange(of: viewModel.messages) { _, newMessages in
                applyWindowMessages(newMessages)
            }
            .onChange(of: isAtBottom) { _, _ in
                scheduleWindowFocusSync()
            }
            .onChange(of: isLiveScrolling) { _, isScrolling in
                ChatPerfTrace.recordScrollState(chatId: chat.id, isScrolling: isScrolling)
                updateLightweightScrollRenderMode(isScrolling: isScrolling)
                Task { @MainActor in
                    await emitWindowingDebugLog(
                        reason: isScrolling ? "scrollStart" : "scrollEnd",
                        chatId: chat.id
                    )
                }
            }
            .onChange(of: windowMessages) { oldMessages, newMessages in
                pruneVisibleMessageIdsToWindow()
                handleWindowMessagesChange(
                    oldMessages: oldMessages,
                    newMessages: newMessages,
                    proxy: proxy
                )
                scheduleWindowFocusSync()
                scheduleTextPrewarm(messages: newMessages)
                maybeRequestOlderForUnderfilledViewport(source: "windowMessagesChanged")
            }
            .onChange(of: store.isLoadingHistory) { _, isLoading in
                guard !isLoading else { return }
                if pagingInFlight, windowMessages.first?.id == paginationBaselineFirstMessageId {
                    clearPagingState()
                }
                let shouldRetryPendingTopRequest =
                    pendingTopVisibleRetryAfterLoading &&
                    didInitialScrollToBottom &&
                    isTopSentinelVisible &&
                    !pagingInFlight
                if shouldRetryPendingTopRequest {
                    pendingTopVisibleRetryAfterLoading = false
                    requestOlderHistoryFromTopTrigger(source: "historyLoadingCompletedRetry")
                }
                maybeRequestOlderForUnderfilledViewport(source: "historyLoadingCompleted")
            }
            .onDisappear {
                rowBuildTask?.cancel()
                rowBuildTask = nil
                isPagingHistory = false
                clearPrependPixelAnchor()
                scrollViewRef.scrollView = nil
                ChatPerfTrace.recordScrollState(chatId: chat.id, isScrolling: false)
                stopWindowingDebugLogging(reason: "disappear")
                cancelWindowFocusSyncTask()
                store.updateMessageWindowFocus(chatId: chat.id, isFollowingLatest: true, anchorMessageId: nil)
                lightweightScrollRenderModeResetTask?.cancel()
                lightweightScrollRenderModeResetTask = nil
                isLightweightScrollRenderMode = false
                visibleReportTask?.cancel()
                visibleReportTask = nil
                visibleMessageIds = []
                store.resetVisibleMessageTracking(chatId: chat.id)
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

private struct GroupRowMinYPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private final class ScrollViewReference {
    weak var scrollView: NSScrollView?
}

private struct ScrollLiveStateObserver: NSViewRepresentable {
    @Binding var isLiveScrolling: Bool
    let onResolveScrollView: (NSScrollView?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isLiveScrolling: $isLiveScrolling,
            onResolveScrollView: onResolveScrollView
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateBinding($isLiveScrolling)
        context.coordinator.updateResolveCallback(onResolveScrollView)
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private var isLiveScrolling: Binding<Bool>
        private var onResolveScrollView: (NSScrollView?) -> Void
        private weak var scrollView: NSScrollView?
        private var willStartObserver: NSObjectProtocol?
        private var didEndObserver: NSObjectProtocol?

        init(
            isLiveScrolling: Binding<Bool>,
            onResolveScrollView: @escaping (NSScrollView?) -> Void
        ) {
            self.isLiveScrolling = isLiveScrolling
            self.onResolveScrollView = onResolveScrollView
        }

        deinit {
            removeObservers()
        }

        func updateBinding(_ binding: Binding<Bool>) {
            isLiveScrolling = binding
        }

        func updateResolveCallback(_ callback: @escaping (NSScrollView?) -> Void) {
            onResolveScrollView = callback
        }

        func attach(to nsView: NSView) {
            DispatchQueue.main.async { [weak self, weak nsView] in
                guard let self, let nsView else { return }
                guard let enclosing = nsView.enclosingScrollView else { return }
                guard self.scrollView !== enclosing else { return }
                self.bind(to: enclosing)
            }
        }

        func detach() {
            removeObservers()
            scrollView = nil
            setLiveScrolling(false)
            onResolveScrollView(nil)
        }

        private func bind(to scrollView: NSScrollView) {
            removeObservers()
            self.scrollView = scrollView
            onResolveScrollView(scrollView)
            let center = NotificationCenter.default
            willStartObserver = center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.setLiveScrolling(true)
            }
            didEndObserver = center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.setLiveScrolling(false)
            }
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            if let willStartObserver {
                center.removeObserver(willStartObserver)
                self.willStartObserver = nil
            }
            if let didEndObserver {
                center.removeObserver(didEndObserver)
                self.didEndObserver = nil
            }
        }

        private func setLiveScrolling(_ value: Bool) {
            guard isLiveScrolling.wrappedValue != value else { return }
            isLiveScrolling.wrappedValue = value
        }
    }
}
