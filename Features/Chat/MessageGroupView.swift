//
//  MessageGroupView.swift
//  Aurora
//

import SwiftUI

struct ChatMessageGroupView: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    let group: MessageGroup

    /// Trackpad “reveal exact time” (0…maxReveal)
    let revealTimeX: CGFloat

    /// Jelly impulse (computed by parent from scroll deltas)
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
                ForEach(group.messages, id: \.messageKey) { msg in
                    MessageBubble(
                        msg: msg,
                        currentChatId: chat.id,
                        revealTimeX: revealTimeX,
                        onRetry: { store.retrySend(message: msg) },
                        onDelete: { store.deleteMessages(chatId: msg.chatId, messageIds: [msg.id], revoke: true) }
                    )
                    .visualEffect { content, proxy in
                        // Anchor jelly to bottom of visible container.
                        let frame = proxy.frame(in: .named(MessagesPane.scrollSpaceName))
                        let distanceToBottom = max(0, jellyContainerHeight - frame.maxY)
                        let k = max(0, 1 - min(distanceToBottom / 360, 1))

                        // Stronger amplitude (you asked for more).
                        let y = (-jellyScrollImpulse * 1.45 * k)
                        let stretch = 1 + min(abs(jellyScrollImpulse) / 320, 0.22) * k
                        return content
                            .scaleEffect(x: 1, y: stretch, anchor: .bottom)
                            .offset(y: y)
                    }
                }
            }
        }
        .onAppear {
            guard !group.isOutgoing else { return }
            let ids = group.messages.map { $0.id }
            store.viewMessages(chatId: chat.id, messageIds: ids, forceRead: false)
        }
        .frame(maxWidth: .infinity, alignment: group.isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
    }
}
