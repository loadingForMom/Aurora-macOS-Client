import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var store = TelegramStore()
    @State private var searchText: String = ""
    @State private var inspectorShown: Bool = false

    private var filteredChats: [TGChat] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = store.sortedChats
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.lowercased().contains(q) ||
            $0.lastMessagePreview.lowercased().contains(q)
        }
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
            if let chatId = store.selectedChatId, let chat = store.chatsById[chatId] {
                ChatScreen(store: store, chat: chat)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            ChatTitleButtonInline(title: chat.title)
                                .onTapGesture { inspectorShown.toggle() }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .inspector(isPresented: $inspectorShown) {
                        ChatInspectorView(chat: chat)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
                    }
            } else {
                ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: store.selectedChatId) { _, newValue in
            guard let id = newValue else { return }
            store.selectChat(id)
        }
    }
}

private struct ChatTitleButtonInline: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.secondary.opacity(0.18))
                .frame(width: 28, height: 28)
                .overlay(
                    Text(initials(from: title))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                )

            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }

    private func initials(from title: String) -> String {
        let parts = title
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }

        if parts.isEmpty, let first = title.first {
            return String(first).uppercased()
        }
        return parts.joined()
    }
}
