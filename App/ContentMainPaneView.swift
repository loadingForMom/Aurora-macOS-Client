//
//  ContentMainPaneView.swift
//  Aurora
//

import SwiftUI

struct ContentMainPaneView: View {
    let store: TelegramStore
    let selectedChatId: Int64?
    @Binding var listSelection: Int64?
    @Binding var inspectorShown: Bool

    @StateObject private var chatListViewModel: ChatListViewModel

    init(
        store: TelegramStore,
        selectedChatId: Int64?,
        listSelection: Binding<Int64?>,
        inspectorShown: Binding<Bool>
    ) {
        self.store = store
        self.selectedChatId = selectedChatId
        _listSelection = listSelection
        _inspectorShown = inspectorShown
        _chatListViewModel = StateObject(wrappedValue: ChatListViewModel(dbPool: store.dbPool))
    }

    private var selectedChat: TGChat? {
        guard let selectedChatId else { return nil }
        return chatListViewModel.chats.first(where: { $0.id == selectedChatId })
    }

    var body: some View {
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "ContentMainPaneView.body",
            details: "selectedChatId=\(selectedChatId.map(String.init) ?? "nil") inspectorShown=\(inspectorShown)"
        )
#endif
        NavigationSplitView {
            ContentSidebarPaneView(
                store: store,
                viewModel: chatListViewModel,
                listSelection: $listSelection
            )
        } detail: {
            ContentDetailPaneView(
                store: store,
                viewModel: chatListViewModel,
                selectedChatId: selectedChatId,
                inspectorShown: $inspectorShown
            )
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .inspector(isPresented: $inspectorShown) {
            if let chat = selectedChat {
                ChatInspectorView(store: store, chat: chat)
                    .inspectorColumnWidth(
                        min: ChatLayoutMetrics.inspectorMinWidth,
                        ideal: ChatLayoutMetrics.inspectorIdealWidth,
                        max: ChatLayoutMetrics.inspectorMaxWidth
                    )
            } else {
                ContentUnavailableView("No chat selected", systemImage: "sidebar.right")
                    .padding(16)
                    .inspectorColumnWidth(
                        min: ChatLayoutMetrics.emptyInspectorMinWidth,
                        ideal: ChatLayoutMetrics.emptyInspectorIdealWidth,
                        max: ChatLayoutMetrics.emptyInspectorMaxWidth
                    )
            }
        }
    }
}
