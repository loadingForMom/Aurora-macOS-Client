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
        _messagesViewModel = StateObject(wrappedValue: ChatMessagesViewModel(store: store, chatId: chat.id))
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
                        SwiftUIPublishTrace.uiEvent(
                            name: "onSend_composer",
                            chatId: chat.id,
                            payload: "textLength=\(t.count)",
                            reason: "uiCallback_sendMessage"
                        )
                        store.sendText(chatId: chat.id, text: t)
                        draft = ""
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.clear)
            }
            .onAppear {
                SwiftUIPublishTrace.uiEvent(
                    name: "onAppear_chatScreen",
                    chatId: chat.id,
                    payload: "draftLength=\(draft.count)",
                    reason: "viewLifecycle"
                )
            }
            .onDisappear {
                SwiftUIPublishTrace.uiEvent(
                    name: "onDisappear_chatScreen",
                    chatId: chat.id,
                    payload: "draftLength=\(draft.count)",
                    reason: "viewLifecycle"
                )
            }
            .task(id: chat.id) {
                SwiftUIPublishTrace.uiEvent(
                    name: "onChange_selectedChat",
                    chatId: chat.id,
                    payload: "chatId=\(chat.id)",
                    reason: "fromSelectionChange"
                )
                draft = ""
            }
            .transaction { _ in
                ViewUpdatePhaseTracker.shared.markUpdating(source: "ChatScreen")
            }
    }
}
