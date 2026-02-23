//
//  ContentDetailPaneView.swift
//  Aurora
//

import SwiftUI
import Combine

struct ContentDetailPaneView: View {
    let store: TelegramStore
    @ObservedObject var viewModel: ChatListViewModel
    let selectedChatId: Int64?
    @Binding var inspectorShown: Bool

    private var selectedChat: TGChat? {
        guard let selectedChatId else { return nil }
        return viewModel.chats.first(where: { $0.id == selectedChatId })
    }

    private var detailMinWidth: CGFloat {
        inspectorShown
            ? ChatLayoutMetrics.detailMinWidthWithInspector
            : ChatLayoutMetrics.detailMinWidthNoInspector
    }

    var body: some View {
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "ContentDetailPaneView.body",
            details: "selectedChatId=\(selectedChatId.map(String.init) ?? "nil") inspectorShown=\(inspectorShown)"
        )
#endif
        Group {
            if let chat = selectedChat {
                ChatScreen(
                    store: store,
                    chat: chat,
                    inspectorShown: $inspectorShown
                )
                .id(chat.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            minWidth: detailMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }
}
