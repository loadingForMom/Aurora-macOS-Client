//
//  ContentView.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: TelegramStore

    @State private var searchText: String = ""
    @State private var inspectorShown: Bool = true // оставил true как у тебя "для теста"

    private var filteredChats: [TGChat] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = store.sortedChats
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(q) ||
            $0.lastMessagePreview.lowercased().contains(q)
        }
    }

    private var selectedChat: TGChat? {
        guard let chatId = store.selectedChatId else { return nil }
        return store.chatsById[chatId]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedChatId) {
                ForEach(filteredChats) { chat in
                    ChatRow(chat: chat)
                        .tag(chat.id as Int64?)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar)
        } detail: {
            Group {
                if let chat = selectedChat {
                    ChatScreen(store: store, chat: chat)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                ChatTitleButtonInline(
                                    title: chat.title,
                                    image: store.chatAvatarNSImage(chatId: chat.id)
                                )
                                .onTapGesture {
                                    // Системный inspector сам красиво анимируется.
                                    inspectorShown.toggle()
                                }
                            }
                        }
                } else {
                    ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(.secondary)
                }
            }
        }
        // ВАЖНО: inspector вешаем на верх иерархии (на NavigationSplitView),
        // так он ведёт себя “нативно” и реально сдвигает контент, а не висит карточкой.
        .inspector(isPresented: $inspectorShown) {
            if let chat = selectedChat {
                ChatInspectorView(chat: chat)
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 420)
            } else {
                ContentUnavailableView("No chat selected", systemImage: "sidebar.right")
                    .padding(16)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
            }
        }
        .task {
            // If selection is already set (e.g. restored), ensure history is loaded once.
            if let id = store.selectedChatId {
                store.selectChat(id, forceReload: false)
            }
        }
        .onChange(of: store.selectedChatId) { _, newChatId in
            // ВАЖНО: List(selection:) меняет selectedChatId сама.
            // Поэтому тут явно просим стор подгрузить историю для выбранного чата.
            guard let id = newChatId else { return }
            store.selectChat(id)

            // Не скрываем инспектор при смене чата (как ты и хотел).
        }
    }
}

// (ChatTitleButtonInline оставляем как был, он нормальный)
struct ChatTitleButtonInline: View {
    let title: String
    let image: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Text(String(title.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }
}
