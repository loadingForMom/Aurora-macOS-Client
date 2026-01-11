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

    init(store: TelegramStore, chat: TGChat) {
        self.store = store
        self.chat = chat
        _messagesViewModel = StateObject(wrappedValue: ChatMessagesViewModel(dbPool: store.dbPool, chatId: chat.id))
    }

    var body: some View {
        MessagesPane(store: store, chat: chat, viewModel: messagesViewModel)
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
                .background(.clear)
            }
            .task(id: chat.id) {
                draft = ""
            }
    }
}
