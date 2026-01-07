//
//  MessageBubble.swift
//  Aurora
//
//  Bubble styling + macOS trackpad timestamp reveal.
//

import SwiftUI

struct MessageBubble: View {
    let msg: TGMessage
    let currentChatId: Int64

    /// Trackpad “reveal exact time” (0…maxReveal), passed from parent.
    let revealTimeX: CGFloat

    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}

    /// Kept for compatibility; jelly is applied via visualEffect in parent now.
    var jellyOffsetY: CGFloat = 0

    private let maxReveal: CGFloat = 72

    init(
        msg: TGMessage,
        currentChatId: Int64,
        revealTimeX: CGFloat = 0,
        onRetry: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        jellyOffsetY: CGFloat = 0
    ) {
        self.msg = msg
        self.currentChatId = currentChatId
        self.revealTimeX = revealTimeX
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.jellyOffsetY = jellyOffsetY
    }

    var body: some View {
#if DEBUG
        let _ = { () -> Void in
            assert(msg.chatId == currentChatId, "Message chatId mismatch: expected \(currentChatId) got \(msg.chatId)")
        }()
#endif
        let reveal = min(max(0, revealTimeX), maxReveal)
        let isRevealingTime = reveal > 0.5

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
        .contextMenu {
            if msg.isOutgoing {
                if case .failed = msg.sendState, msg.canRetry {
                    Button("Retry") { onRetry() }
                }
                Button("Delete") { onDelete() }
            }
        }
    }

    @ViewBuilder
    private func content(isRevealingTime: Bool) -> some View {
        VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 4) {
            Text(msg.text)
                .foregroundStyle(msg.isOutgoing ? .white : .primary)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )

            if !isRevealingTime {
                HStack(spacing: 6) {
                    if msg.isEdited {
                        Text("edited")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    statusView
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                if case .sent = msg.sendState {
                    EmptyView()
                } else {
                    statusView
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
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
