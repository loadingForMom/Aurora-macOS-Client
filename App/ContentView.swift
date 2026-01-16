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
    @State private var inspectorShown: Bool = true

    private func filteredChats(_ base: [TGChat], query: String) -> [TGChat] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }

        // NOTE: we only use chat fields here (not store.messagesByChatId),
        // so the sidebar won't rerender on every message update.
        return base.filter {
            $0.title.lowercased().contains(q) ||
            $0.lastMessagePreview.lowercased().contains(q)
        }
    }

    private func sidebarPreview(for chat: TGChat) -> String {
        // TelegramStore already keeps this “truthful” (optimistic pending/failed) in chat.lastMessagePreview.
        return chat.lastMessagePreview.isEmpty ? chat.kind.label : chat.lastMessagePreview
    }

    private func avatarPath(for chatId: Int64) -> String? {
        store.chatAvatarPathByChatId[chatId]
    }

    private var selectedChat: TGChat? {
        guard let chatId = store.selectedChatId else { return nil }
        return store.chatsById[chatId]
    }

    var body: some View {
        let baseChats = store.sortedChats
        let chats = filteredChats(baseChats, query: searchText)

        NavigationSplitView {
            List(selection: $store.selectedChatId) {
                ForEach(chats) { chat in
                    ChatRow(
                        chat: chat,
                        previewText: sidebarPreview(for: chat),
                        avatarPath: avatarPath(for: chat.id)
                    )
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
                                    avatarPath: avatarPath(for: chat.id)
                                )
                                .onTapGesture {
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
            if let id = store.selectedChatId {
                store.selectChat(id, forceReload: false)
            }
        }
        .onChange(of: store.selectedChatId) { _, newChatId in
            guard let id = newChatId else { return }
            store.selectChat(id)
        }
    }
}

struct ChatTitleButtonInline: View {
    let title: String
    let avatarPath: String?

    var body: some View {
        HStack(spacing: 8) {
            AvatarCircle(
                title: title,
                path: avatarPath,
                size: 28,
                font: .system(size: 11, weight: .semibold, design: .rounded)
            )
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
