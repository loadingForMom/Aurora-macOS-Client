//
//  MessageGroupView.swift
//  Aurora
//

import SwiftUI


struct ChatMessageGroupView: View {
    let chatId: Int64
    let isGroupChat: Bool
    let group: MessageGroup
    let senderName: String?
    let optimizeForLargeTimeline: Bool
    let isLiveScrolling: Bool
    let isScrollPerformanceMode: Bool
    let mediaService: MediaService
    let mediaProgressProvider: MediaProgressProvider
    let onRetryMessage: (TGMessage) -> Void
    let onDeleteMessage: (TGMessage) -> Void
    let onMessageVisibilityChange: (Int64, Bool) -> Void

    /// Trackpad “reveal exact time” (0…maxReveal)
    let revealTimeX: CGFloat

    /// Jelly impulse (computed by parent from scroll deltas)
    let jellyScrollImpulse: CGFloat

    init(
        chatId: Int64,
        isGroupChat: Bool,
        group: MessageGroup,
        senderName: String? = nil,
        optimizeForLargeTimeline: Bool = false,
        isLiveScrolling: Bool = false,
        isScrollPerformanceMode: Bool = false,
        revealTimeX: CGFloat = 0,
        jellyScrollImpulse: CGFloat = 0,
        mediaService: MediaService,
        mediaProgressProvider: MediaProgressProvider,
        onRetryMessage: @escaping (TGMessage) -> Void = { _ in },
        onDeleteMessage: @escaping (TGMessage) -> Void = { _ in },
        onMessageVisibilityChange: @escaping (Int64, Bool) -> Void = { _, _ in }
    ) {
        self.chatId = chatId
        self.isGroupChat = isGroupChat
        self.group = group
        self.senderName = senderName
        self.optimizeForLargeTimeline = optimizeForLargeTimeline
        self.isLiveScrolling = isLiveScrolling
        self.isScrollPerformanceMode = isScrollPerformanceMode
        self.revealTimeX = revealTimeX
        self.jellyScrollImpulse = jellyScrollImpulse
        self.mediaService = mediaService
        self.mediaProgressProvider = mediaProgressProvider
        self.onRetryMessage = onRetryMessage
        self.onDeleteMessage = onDeleteMessage
        self.onMessageVisibilityChange = onMessageVisibilityChange
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
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "ChatMessageGroupView.body",
            details: "chatId=\(chatId) groupId=\(group.id) messages=\(group.messages.count) outgoing=\(group.isOutgoing)"
        )
#endif
        let enableJelly = abs(jellyScrollImpulse) > 0.5
            && group.messages.count < 60
        let stretch = enableJelly ? (1 + min(abs(jellyScrollImpulse) / 320, 0.18)) : 1
        let y = enableJelly ? (-jellyScrollImpulse * 1.1) : 0

        VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 6) {
            if isGroupChat && !group.isOutgoing {
                if let senderName, !senderName.isEmpty {
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }

            VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(group.messages, id: \.id) { msg in
                    MessageBubble(
                        msg: msg,
                        currentChatId: chatId,
                        revealTimeX: revealTimeX,
                        heavyEffectsDisabled: heavyEffectsDisabled,
                        isLiveScrolling: isLiveScrolling,
                        isScrollPerformanceMode: isScrollPerformanceMode,
                        mediaService: mediaService,
                        mediaStateObserver: mediaProgressProvider.observer(
                            chatId: msg.chatId,
                            messageId: msg.id
                        ),
                        onRetry: { onRetryMessage(msg) },
                        onDelete: { onDeleteMessage(msg) }
                    )
                    .id(msg.id)
                    .onAppear {
                        onMessageVisibilityChange(msg.id, true)
                    }
                    .onDisappear {
                        onMessageVisibilityChange(msg.id, false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: group.isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
        .scaleEffect(x: 1, y: stretch, anchor: .bottom)
        .offset(y: y)
        .onAppear {
#if DEBUG
            PerfCounters.bumpEvent(
                "ChatMessageGroupView.onAppear",
                details: "chatId=\(chatId) groupId=\(group.id) messages=\(group.messages.count)"
            )
#endif
            recordHeavyEffectsDisabledIfNeeded()
        }
        .onChange(of: heavyEffectsDisabled) { _, disabled in
#if DEBUG
            PerfCounters.bumpEvent(
                "ChatMessageGroupView.onChangeHeavyEffectsDisabled",
                details: "chatId=\(chatId) groupId=\(group.id) disabled=\(disabled)"
            )
#endif
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
        ChatPerfTrace.recordHeavyEffectsDisabled(chatId: chatId, count: group.messages.count)
    }
}

private struct ChatMessageGroupViewPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview
    private let mediaProgressProvider = MediaProgressProvider()

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
                chatId: chat.id,
                isGroupChat: true,
                group: previewGroup,
                senderName: "Preview Sender",
                mediaService: store.mediaService,
                mediaProgressProvider: mediaProgressProvider,
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
