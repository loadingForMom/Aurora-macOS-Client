//
//  MessageBubble.swift
//  Aurora
//
//  iMessage-ish bubble styling using system materials.
//

import SwiftUI

struct MessageBubble: View {
    let msg: TGMessage

    // Defaults so call sites can just do MessageBubble(msg: msg)
    var onRetry: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 4) {
            Text(msg.text)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )

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
        }
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
        msg.isOutgoing ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial)
    }

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
