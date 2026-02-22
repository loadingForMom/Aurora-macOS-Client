//
//  ChatScreen.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct ChatScreen: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    @StateObject private var messagesViewModel: ChatMessagesViewModel

    @State private var draft: String = ""
    @State private var isPagingHistory: Bool = false

    init(
        store: TelegramStore,
        chat: TGChat
    ) {
        self.store = store
        self.chat = chat
        _messagesViewModel = StateObject(wrappedValue: ChatMessagesViewModel(store: store, chatId: chat.id))
    }

    var body: some View {
        MessagesPane(
            store: store,
            chat: chat,
            viewModel: messagesViewModel,
            isPagingHistory: $isPagingHistory
        )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GlassComposerBar(
                    text: $draft,
                    onPlus: {
                        // TODO: stub
                    },
                    onSend: {
                        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        store.sendText(chatId: chat.id, text: t)
                        draft = ""
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .task(id: chat.id) {
                draft = ""
            }
    }
}

private struct ChatScreenPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview

    private let chat = TGChat(
        id: 101,
        title: "Preview Playground",
        kind: .basicGroup,
        order: 9_999_999,
        lastMessagePreview: "Looks great. Let's ship this setup.",
        lastMessageDate: Int(Date().timeIntervalSince1970) - 75
    )

    var body: some View {
        ChatScreen(
            store: store,
            chat: chat
        )
        .environmentObject(store)
        .frame(width: 980, height: 680)
    }
}

#Preview("ChatScreen") {
    ChatScreenPreviewContainer()
}
