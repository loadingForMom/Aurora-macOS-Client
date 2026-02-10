//
//  MessageGroupView.swift
//  Aurora
//

import SwiftUI


struct ChatMessageGroupView: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    let group: MessageGroup
    let optimizeForLargeTimeline: Bool
    let isScrolling: Bool
    let onMessageAppear: (Int64) -> Void
    let onMessageDisappear: (Int64) -> Void

    /// Trackpad “reveal exact time” (0…maxReveal)
    let revealTimeX: CGFloat

    /// Jelly impulse (computed by parent from scroll deltas)
    let jellyScrollImpulse: CGFloat

    init(
        store: TelegramStore,
        chat: TGChat,
        group: MessageGroup,
        optimizeForLargeTimeline: Bool = false,
        isScrolling: Bool = false,
        revealTimeX: CGFloat = 0,
        jellyScrollImpulse: CGFloat = 0,
        onMessageAppear: @escaping (Int64) -> Void = { _ in },
        onMessageDisappear: @escaping (Int64) -> Void = { _ in }
    ) {
        self.store = store
        self.chat = chat
        self.group = group
        self.optimizeForLargeTimeline = optimizeForLargeTimeline
        self.isScrolling = isScrolling
        self.revealTimeX = revealTimeX
        self.jellyScrollImpulse = jellyScrollImpulse
        self.onMessageAppear = onMessageAppear
        self.onMessageDisappear = onMessageDisappear
    }

    var body: some View {
        let lightweightRenderMode = optimizeForLargeTimeline || isScrolling
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
                ForEach(group.messages, id: \.id) { msg in
                    MessageBubble(
                        msg: msg,
                        currentChatId: chat.id,
                        revealTimeX: revealTimeX,
                        optimizeForPerformance: lightweightRenderMode,
                        isScrolling: isScrolling,
                        onRetry: { store.retrySend(message: msg) },
                        onDelete: { store.deleteMessages(chatId: msg.chatId, messageIds: [msg.id], revoke: true) }
                    )
                    .id(msg.id)
                    .onAppear {
                        onMessageAppear(msg.id)
                    }
                    .onDisappear {
                        onMessageDisappear(msg.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: group.isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
        .scaleEffect(x: 1, y: stretch, anchor: .bottom)
        .offset(y: y)
        .transaction { transaction in
            if isScrolling {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }
}
