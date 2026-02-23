//
//  ChatScreen.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct ChatScreen: View {
    @ObservedObject var store: TelegramStore
    @EnvironmentObject private var settingsStore: SettingsStore
    let chat: TGChat
    @Binding var inspectorShown: Bool
    @StateObject private var messagesViewModel: ChatMessagesViewModel
    @StateObject private var aiViewModel = ChatViewModel()

    @State private var draft: String = ""
    @State private var isPagingHistory: Bool = false

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        store: TelegramStore,
        chat: TGChat,
        inspectorShown: Binding<Bool>
    ) {
        self.store = store
        self.chat = chat
        _inspectorShown = inspectorShown
        _messagesViewModel = StateObject(wrappedValue: ChatMessagesViewModel(store: store, chatId: chat.id))
    }

    var body: some View {
        MessagesPane(
            store: store,
            chat: chat,
            viewModel: messagesViewModel,
            isPagingHistory: $isPagingHistory
        )
            .safeAreaInset(edge: .top, spacing: 0) {
                ChatTopProfileAvatarView(
                    store: store,
                    chat: chat,
                    onTitleTap: {
                        inspectorShown.toggle()
                    }
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    SuggestionsView(suggestions: aiViewModel.suggestions) { suggestion in
                        aiViewModel.onTapSuggestion(suggestion, text: &draft)
                    }

                    if let errorMessage = aiViewModel.errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    GlassComposerBar(
                        text: $draft,
                        onPlus: {
                            // TODO: stub
                        },
                        onGenerate: {
                            aiViewModel.onTapGenerate(last3: recentMessagesForAI)
                        },
                        isGeneratingSuggestions: aiViewModel.isLoading,
                        onSend: {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            store.sendText(chatId: chat.id, text: t)
                            draft = ""
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .animation(.easeInOut(duration: 0.16), value: aiViewModel.suggestions.isEmpty)
                .animation(.easeInOut(duration: 0.16), value: aiViewModel.errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: chat.id) {
                draft = ""
                aiViewModel.clearState()
            }
    }

    private var recentMessagesForAI: [ChatMsg] {
        let contextCount = max(1, settingsStore.aiContextMessageCount)
        return messagesViewModel.messages
            .suffix(contextCount)
            .compactMap { (message: TGMessage) -> ChatMsg? in
                let messageText = (message.textForRendering ?? message.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !messageText.isEmpty else {
                    return nil
                }

                let isoDate = message.date > 0
                    ? Self.isoDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.date)))
                    : nil

                return ChatMsg(
                    role: message.isOutgoing ? .assistant : .user,
                    text: messageText,
                    date: isoDate
                )
            }
    }
}

private struct ChatScreenPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview
    @StateObject private var settingsStore = SettingsStore()
    @State private var inspectorShown = false

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
            chat: chat,
            inspectorShown: $inspectorShown
        )
        .environmentObject(store)
        .environmentObject(settingsStore)
        .frame(width: 980, height: 680)
    }
}

#Preview("ChatScreen") {
    ChatScreenPreviewContainer()
}
