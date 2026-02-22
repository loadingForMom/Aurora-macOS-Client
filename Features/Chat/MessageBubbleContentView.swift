//
//  MessageBubbleContentView.swift
//  Aurora
//

import SwiftUI

struct MessageBubbleContentView: View {
    let msg: TGMessage
    let bubbleMaxWidth: CGFloat
    let isRevealingTime: Bool
    let heavyEffectsDisabled: Bool
    let isLiveScrolling: Bool
    let isScrollPerformanceMode: Bool
    let mediaService: MediaService
    let mediaStateObserver: MediaProgressProvider.Observer
    let onRetry: () -> Void

    var body: some View {
        let hideStatusLine = isRevealingTime && isSentState
        let hasMedia = mediaDescriptor != nil
        let shouldRenderText = shouldRenderTextContent

        VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: 4) {
            VStack(alignment: msg.isOutgoing ? .trailing : .leading, spacing: hasMedia && shouldRenderText ? 8 : 0) {
                if let descriptor = mediaDescriptor {
                    MessageMediaAttachmentView(
                        chatId: msg.chatId,
                        messageId: msg.id,
                        descriptor: descriptor,
                        isLiveScrolling: isLiveScrolling,
                        isScrollPerformanceMode: isScrollPerformanceMode,
                        mediaService: mediaService,
                        mediaStateObserver: mediaStateObserver,
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, shouldRenderText ? 0 : 8)
                }

                if shouldRenderText {
                    BubbleTextView(
                        chatId: msg.chatId,
                        messageId: msg.id,
                        rawText: msg.textForRendering,
                        entities: msg.entities,
                        isOutgoing: msg.isOutgoing,
                        textSelectionEnabled: !isLiveScrolling
                    )
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

                if msg.isOutgoing {
                    shape.fill(Color(nsColor: .systemBlue).opacity(0.5))
                } else {
                    ZStack {
                        shape
                            .fill(Color.white.opacity(0.2))

                        Color.clear
                            .glassEffect(.clear, in: shape)
                            .clipShape(shape)
                    }
                }
            }
            .overlay {
                if !heavyEffectsDisabled {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
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

    private var mediaDescriptor: TGMessageMediaDescriptor? {
        guard msg.contentType == "messagePhoto" || msg.contentType == "messageVideo" else { return nil }
        return msg.media
    }

    private var shouldRenderTextContent: Bool {
        if mediaDescriptor != nil {
            guard let text = msg.textForRendering?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !text.isEmpty
        }
        return true
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

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
