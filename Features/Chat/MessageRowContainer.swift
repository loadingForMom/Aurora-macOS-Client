//
//  MessageRowContainer.swift
//  Aurora
//

import SwiftUI

enum MessageRowAction: Sendable {
    case visibilityChanged(messageId: Int64, isVisible: Bool)
}

struct MessageRowContainer: View, Equatable {
    let row: MessagesPane.Row
    let chatId: Int64
    let isGroupChat: Bool
    let senderName: String?
    let optimizeForLargeTimeline: Bool
    let isLiveScrolling: Bool
    let isScrollPerformanceMode: Bool
    let revealTimeX: CGFloat
    let shouldMeasureMinY: Bool
    let scrollSpaceName: String
    let mediaService: MediaService
    let mediaProgressProvider: MediaProgressProvider
    let onRetryMessage: (TGMessage) -> Void
    let onDeleteMessage: (TGMessage) -> Void
    let onAction: (MessageRowAction) -> Void

    static func == (lhs: MessageRowContainer, rhs: MessageRowContainer) -> Bool {
        // Ignore callback identity so diffing follows row inputs only.
        lhs.row == rhs.row
            && lhs.chatId == rhs.chatId
            && lhs.isGroupChat == rhs.isGroupChat
            && lhs.senderName == rhs.senderName
            && lhs.optimizeForLargeTimeline == rhs.optimizeForLargeTimeline
            && lhs.isLiveScrolling == rhs.isLiveScrolling
            && lhs.isScrollPerformanceMode == rhs.isScrollPerformanceMode
            && lhs.revealTimeX == rhs.revealTimeX
            && lhs.shouldMeasureMinY == rhs.shouldMeasureMinY
            && lhs.scrollSpaceName == rhs.scrollSpaceName
            && ObjectIdentifier(lhs.mediaService) == ObjectIdentifier(rhs.mediaService)
            && lhs.mediaProgressProvider === rhs.mediaProgressProvider
    }

    var body: some View {
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "MessageRowContainer.body",
            details: "chatId=\(chatId) rowId=\(row.id) isLiveScrolling=\(isLiveScrolling)"
        )
#endif
        rowContent
            .background(rowMeasurementOverlay)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row {
        case .dayHeader(_, let day):
            MessageRowDayHeaderView(day: day)

        case .timeSeparator(_, let date):
            MessageRowTimeSeparatorView(date: date)

        case .group(let group):
            ChatMessageGroupView(
                chatId: chatId,
                isGroupChat: isGroupChat,
                group: group,
                senderName: senderName,
                optimizeForLargeTimeline: optimizeForLargeTimeline,
                isLiveScrolling: isLiveScrolling,
                isScrollPerformanceMode: isScrollPerformanceMode,
                revealTimeX: revealTimeX,
                jellyScrollImpulse: 0,
                mediaService: mediaService,
                mediaProgressProvider: mediaProgressProvider,
                onRetryMessage: onRetryMessage,
                onDeleteMessage: onDeleteMessage,
                onMessageVisibilityChange: handleVisibilityChange
            )
            .id(group.id)
        }
    }

    @ViewBuilder
    private var rowMeasurementOverlay: some View {
        switch row {
        case .group:
            if shouldMeasureMinY {
                // swiftui-allow:geometryreader Required to publish exact row offset for prepend-anchor restoration.
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: GroupRowMinYPreferenceKey.self,
                        value: [row.id: geometry.frame(in: .named(scrollSpaceName)).minY]
                    )
                }
            } else {
                Color.clear
            }

        case .dayHeader, .timeSeparator:
            Color.clear
        }
    }

    private func handleVisibilityChange(messageId: Int64, isVisible: Bool) {
        onAction(.visibilityChanged(messageId: messageId, isVisible: isVisible))
    }
}

private enum MessageRowFormatters {
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

private struct MessageRowDayHeaderView: View {
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
        return MessageRowFormatters.dayFormatter.string(from: date)
    }
}

private struct MessageRowTimeSeparatorView: View {
    let date: Date

    var body: some View {
        Text(MessageRowFormatters.timeFormatter.string(from: date))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
