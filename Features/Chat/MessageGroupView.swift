//
//  MessageGroupView.swift
//  Aurora
//

import SwiftUI

struct ChatMessageGroupView: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    let group: MessageGroup

    // Trackpad “reveal exact time” (0…maxReveal)
    let revealTimeX: CGFloat

    // Jelly inputs (computed by parent from scroll offset deltas).
    let jellyScrollImpulse: CGFloat
    let jellyContainerHeight: CGFloat

    init(
        store: TelegramStore,
        chat: TGChat,
        group: MessageGroup,
        revealTimeX: CGFloat = 0,
        jellyScrollImpulse: CGFloat = 0,
        jellyContainerHeight: CGFloat = 0
    ) {
        self.store = store
        self.chat = chat
        self.group = group
        self.revealTimeX = revealTimeX
        self.jellyScrollImpulse = jellyScrollImpulse
        self.jellyContainerHeight = jellyContainerHeight
    }

    var body: some View {
        VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 6) {
            if chat.kind.isGroup && !group.isOutgoing {
                let name = store.userDisplayName(group.senderUserId)
                if !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }

            VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(group.messages) { msg in
                    MessageBubble(
                        msg: msg,
                        revealTimeX: revealTimeX,
                        onRetry: { store.retrySend(message: msg) },
                        onDelete: { store.deleteMessages(chatId: msg.chatId, messageIds: [msg.id], revoke: true) }
                    )
                    .applyIf(abs(jellyScrollImpulse) > 0.01) { view in
                        view.visualEffect { content, proxy in
                            // Use named coordinate space (macOS-safe, no .scrollView dependency).
                            let frame = proxy.frame(in: .named(MessagesPane.scrollSpaceName))
                            let distanceToBottom = max(0, jellyContainerHeight - frame.maxY)

                            // 0…1: near bottom = stronger, higher up = weaker
                            let k = max(0, 1 - min(distanceToBottom / 320, 1))

                            // Stronger amplitude knobs:
                            //  - impulse multiplier controls “stretch” during scroll
                            let y = (-jellyScrollImpulse * 0.55 * k)
                            return content.offset(y: y)
                        }
                    }
                }
            }
        }
        .onAppear {
            // Mark incoming messages as viewed when they become visible.
            guard !group.isOutgoing else { return }
            let ids = group.messages.map { $0.id }
            store.viewMessages(chatId: chat.id, messageIds: ids, forceRead: false)
        }
        .frame(maxWidth: .infinity, alignment: group.isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
    }
}

// Small helper to conditionally apply modifiers without wrecking type inference.
private extension View {
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
