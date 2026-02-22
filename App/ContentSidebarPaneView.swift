//
//  ContentSidebarPaneView.swift
//  Aurora
//

import SwiftUI
import Combine
import AppKit

struct ContentSidebarPaneView: View {
    let store: TelegramStore
    @ObservedObject var viewModel: ChatListViewModel
    @Binding var listSelection: Int64?

    @State private var searchText: String = ""
    @State private var avatarPathByChatId: [Int64: String] = [:]
    @State private var avatarVersionByChatId: [Int64: Int] = [:]

    var body: some View {
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "ContentSidebarPaneView.body",
            details: "filteredChats=\(viewModel.filteredChats.count) searchLen=\(searchText.count)"
        )
#endif
        List(selection: $listSelection) {
            ForEach(viewModel.filteredChats) { chat in
                let avatarPath = avatarPathByChatId[chat.id]
                let avatarRevision = avatarRevision(for: chat.id, avatarPath: avatarPath)
                let chatId = chat.id
                ChatRow(
                    chat: chat,
                    previewText: sidebarPreview(for: chat),
                    avatarPath: avatarPath,
                    avatarRevision: avatarRevision,
                    avatarImageProvider: { [store, chatId, avatarPath] in
                        if let image = await store.chatAvatarNSImageAsync(
                            chatId: chatId,
                            pointSize: 34,
                            preferHiRes: false
                        ) {
                            return image
                        }
                        guard let avatarPath else { return nil }
                        return await DiskImageCache.shared.imageAsync(path: avatarPath)
                    }
                )
                .tag(chat.id as Int64?)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard listSelection != chat.id else { return }
#if DEBUG
                    PerfCounters.bumpEvent(
                        "ContentSidebarPaneView.onTap.chatRow",
                        details: "chatId=\(chat.id)"
                    )
#endif
                    // Keep selection deterministic even when List selection lags updates.
                    listSelection = chat.id
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar)
        .navigationSplitViewColumnWidth(
            min: ChatLayoutMetrics.sidebarMinWidth,
            ideal: ChatLayoutMetrics.sidebarIdealWidth,
            max: ChatLayoutMetrics.sidebarMaxWidth
        )
        .onChange(of: searchText) { _, nextQuery in
#if DEBUG
            PerfCounters.bumpEvent(
                "ContentSidebarPaneView.onChange.searchText",
                details: "searchLen=\(nextQuery.count)"
            )
#endif
            viewModel.updateSearchQuery(nextQuery)
        }
        .onReceive(store.$chatAvatarPathByChatId.removeDuplicates()) { nextPaths in
            avatarPathByChatId = nextPaths
        }
        .onReceive(store.$chatAvatarVersionByChatId.removeDuplicates()) { nextVersions in
            avatarVersionByChatId = nextVersions
        }
        .onAppear {
            avatarPathByChatId = store.chatAvatarPathByChatId
            avatarVersionByChatId = store.chatAvatarVersionByChatId
            viewModel.updateSearchQuery(searchText)
        }
    }

    private func sidebarPreview(for chat: TGChat) -> String {
        chat.lastMessagePreview.isEmpty ? chat.kind.label : chat.lastMessagePreview
    }

    private func avatarRevision(for chatId: Int64, avatarPath: String?) -> String {
        let version = avatarVersionByChatId[chatId] ?? 0
        return "\(avatarPath ?? "nil")#\(version)"
    }
}
