//
//  MessageBubble.swift
//  Aurora
//
//  Bubble styling + macOS trackpad timestamp reveal.
//

import SwiftUI
import AppKit

struct MessageBubble: View {
    let msg: TGMessage
    let currentChatId: Int64

    /// Trackpad “reveal exact time” (0…maxReveal), passed from parent.
    let revealTimeX: CGFloat

    /// Simplified rendering mode for dense windows.
    let optimizeForPerformance: Bool

    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Kept for compatibility; jelly is applied by the parent at the group level.
    var jellyOffsetY: CGFloat = 0

    private let maxReveal: CGFloat = 72
    private let bubbleMaxWidth: CGFloat = 560

    init(
        msg: TGMessage,
        currentChatId: Int64,
        revealTimeX: CGFloat = 0,
        optimizeForPerformance: Bool = false,
        onRetry: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        jellyOffsetY: CGFloat = 0
    ) {
        self.msg = msg
        self.currentChatId = currentChatId
        self.revealTimeX = revealTimeX
        self.optimizeForPerformance = optimizeForPerformance
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.jellyOffsetY = jellyOffsetY

    }

    var body: some View {
        let reveal = min(max(0, revealTimeX), maxReveal)
        let isRevealingTime = reveal > 0.5

        return Group {
            if msg.chatId != currentChatId {
#if DEBUG
                Text("[debug] message/chat mismatch")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
#else
                EmptyView()
#endif
            } else {
                ZStack(alignment: .trailing) {
                    HStack {
                        if msg.isOutgoing { Spacer(minLength: 40) }

                        content(isRevealingTime: isRevealingTime)
                            .offset(x: -reveal)

                        if !msg.isOutgoing { Spacer(minLength: 40) }
                    }

                    if isRevealingTime {
                        Text(exactTime(msg.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .opacity(min(1, reveal / 16))
                            .offset(x: (maxReveal - reveal))
                            .padding(.trailing, 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: msg.isOutgoing ? .trailing : .leading)
                .offset(y: jellyOffsetY)
                .modifier(MessageContextMenuModifier(enabled: !optimizeForPerformance, msg: msg, onRetry: onRetry, onDelete: onDelete))
            }
        }
    }

    private struct MessageContextMenuModifier: ViewModifier {
        let enabled: Bool
        let msg: TGMessage
        let onRetry: () -> Void
        let onDelete: () -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.contextMenu {
                    if let copyText = msg.textForRendering?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !copyText.isEmpty {
                        Button("Copy") {
                            copyToPasteboard(copyText)
                        }
                    }

                    if msg.isOutgoing {
                        if case .failed = msg.sendState, msg.canRetry {
                            Button("Retry") { onRetry() }
                        }
                        Button("Delete") { onDelete() }
                    }
                }
            } else {
                content
            }
        }

        private func copyToPasteboard(_ value: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    @ViewBuilder
    private func content(isRevealingTime: Bool) -> some View {
        let hideStatusLine = isRevealingTime && isSentState

        VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 4) {
            BubbleTextView(
                chatId: msg.chatId,
                messageId: msg.id,
                rawText: msg.textForRendering,
                entities: msg.entities,
                isOutgoing: msg.isOutgoing,
                textSelectionEnabled: !optimizeForPerformance
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if !optimizeForPerformance {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
            }

            HStack(spacing: 6) {
                if msg.isEdited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(isRevealingTime ? 0 : 1)
                }
                statusView
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            // Keep status row in layout while revealing so bubbles do not jump on Y.
            .opacity(hideStatusLine ? 0 : 1)
            .allowsHitTesting(!hideStatusLine)
        }
        .frame(maxWidth: bubbleMaxWidth, alignment: msg.isOutgoing ? .trailing : .leading)
    }

    private var isSentState: Bool {
        if case .sent = msg.sendState { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch msg.sendState {
        case .sent:
            Text(relativeTime(msg.date))

        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }

        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }

        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)

                if msg.canRetry {
                    Button("Retry") { onRetry() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                } else {
                    Text("Failed")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if msg.isOutgoing {
            // Make outgoing bubbles always “Messages blue” on macOS.
            return AnyShapeStyle(Color(nsColor: .systemBlue))
        } else {
            if optimizeForPerformance {
                return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
            }
            return AnyShapeStyle(.thinMaterial)
        }
    }

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func exactTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.timeFormatter.string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

private struct BubbleTextView: View {
    let chatId: Int64
    let messageId: Int64
    let rawText: String?
    let entities: [TGTextEntity]
    let isOutgoing: Bool
    let textSelectionEnabled: Bool

    @State private var attributed: AttributedString

    init(
        chatId: Int64,
        messageId: Int64,
        rawText: String?,
        entities: [TGTextEntity],
        isOutgoing: Bool,
        textSelectionEnabled: Bool
    ) {
        self.chatId = chatId
        self.messageId = messageId
        self.rawText = rawText
        self.entities = entities
        self.isOutgoing = isOutgoing
        self.textSelectionEnabled = textSelectionEnabled
        _attributed = State(
            initialValue: MessageTextPipeline.render(
                chatId: chatId,
                messageId: messageId,
                rawText: rawText,
                entities: entities,
                style: .bubbleBody
            )
        )
    }

    var body: some View {
        Group {
            if textSelectionEnabled {
                Text(attributed)
                    .textSelection(.enabled)
            } else {
                Text(attributed)
                    .textSelection(.disabled)
            }
        }
        .foregroundStyle(isOutgoing ? .white : .primary)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: messageId) { _, _ in
            rerender()
        }
        .onChange(of: rawText) { _, _ in
            rerender()
        }
        .onChange(of: entities) { _, _ in
            rerender()
        }
    }

    private func rerender() {
        attributed = MessageTextPipeline.render(
            chatId: chatId,
            messageId: messageId,
            rawText: rawText,
            entities: entities,
            style: .bubbleBody
        )
    }
}
