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

    @State private var draft: String = ""

    var body: some View {
        MessagesPane(store: store, chat: chat)
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
                // UI-only: reset draft whenever we enter/switch chats.
                // (Chat selection + history loading should be handled elsewhere as the single source of truth.)
                draft = ""
            }
    }
}
