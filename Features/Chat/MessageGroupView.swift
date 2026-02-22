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
    let isLiveScrolling: Bool
    let isScrollPerformanceMode: Bool
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
        isLiveScrolling: Bool = false,
        isScrollPerformanceMode: Bool = false,
        revealTimeX: CGFloat = 0,
        jellyScrollImpulse: CGFloat = 0,
        onMessageAppear: @escaping (Int64) -> Void = { _ in },
        onMessageDisappear: @escaping (Int64) -> Void = { _ in }
    ) {
        self.store = store
        self.chat = chat
        self.group = group
        self.optimizeForLargeTimeline = optimizeForLargeTimeline
        self.isLiveScrolling = isLiveScrolling
        self.isScrollPerformanceMode = isScrollPerformanceMode
        self.revealTimeX = revealTimeX
        self.jellyScrollImpulse = jellyScrollImpulse
        self.onMessageAppear = onMessageAppear
        self.onMessageDisappear = onMessageDisappear
    }

    private var heavyEffectsDisabled: Bool {
        optimizeForLargeTimeline || isScrollPerformanceMode
    }

    private var disablesAnimations: Bool {
        isLiveScrolling || isScrollPerformanceMode
    }

    private var scrollPerfModeActive: Bool {
        isLiveScrolling || isScrollPerformanceMode
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
                ForEach(group.messages, id: \.id) { msg in
                    MessageBubble(
                        store: store,
                        msg: msg,
                        currentChatId: chat.id,
                        revealTimeX: revealTimeX,
                        heavyEffectsDisabled: heavyEffectsDisabled,
                        isLiveScrolling: isLiveScrolling,
                        isScrollPerformanceMode: isScrollPerformanceMode,
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
        .onAppear {
            recordHeavyEffectsDisabledIfNeeded()
        }
        .onChange(of: heavyEffectsDisabled) { _, disabled in
            guard disabled else { return }
            recordHeavyEffectsDisabledIfNeeded()
        }
        .transaction { transaction in
            if disablesAnimations {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
    }

    private func recordHeavyEffectsDisabledIfNeeded() {
        guard scrollPerfModeActive else { return }
        ChatPerfTrace.recordHeavyEffectsDisabled(chatId: chat.id, count: group.messages.count)
    }
}

private struct ChatMessageGroupViewPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview

    private let chat = TGChat(
        id: 101,
        title: "Preview Playground",
        kind: .basicGroup
    )

    private var previewGroup: MessageGroup {
        let now = Int(Date().timeIntervalSince1970)
        return MessageGroup(
            id: "preview-group",
            isOutgoing: false,
            senderUserId: 7_002,
            messages: [
                TGMessage(
                    id: 1,
                    chatId: 101,
                    date: now - 120,
                    isOutgoing: false,
                    senderUserId: 7_002,
                    text: "Morning! The SwiftUI snapshot now renders instantly."
                ),
                TGMessage(
                    id: 2,
                    chatId: 101,
                    date: now - 95,
                    isOutgoing: false,
                    senderUserId: 7_002,
                    text: "Looks great. Let's ship this setup."
                )
            ]
        )
    }

    var body: some View {
        ScrollView {
            ChatMessageGroupView(
                store: store,
                chat: chat,
                group: previewGroup
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 260)
    }
}

#Preview("ChatMessageGroupView") {
    ChatMessageGroupViewPreviewContainer()
}
