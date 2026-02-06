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

    init(
        store: TelegramStore,
        chat: TGChat,
        group: MessageGroup,
        revealTimeX: CGFloat = 0,
        jellyScrollImpulse: CGFloat = 0
    ) {
        self.store = store
        self.chat = chat
        self.group = group
        self.revealTimeX = revealTimeX
        self.jellyScrollImpulse = jellyScrollImpulse
    }

    var body: some View {
        let enableJelly = abs(jellyScrollImpulse) > 0.5
            && group.messages.count < 60
        let stretch = enableJelly ? (1 + min(abs(jellyScrollImpulse) / 320, 0.18)) : 1
        let y = enableJelly ? (-jellyScrollImpulse * 1.1) : 0

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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: group.isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
        .scaleEffect(x: 1, y: stretch, anchor: .bottom)
        .offset(y: y)
    }
}
