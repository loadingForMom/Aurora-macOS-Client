//
//  ChatScreen.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit

struct ChatScreen: View {
    @ObservedObject var store: TelegramStore
    @EnvironmentObject private var headerDebug: ChatHeaderDebugState
    let chat: TGChat
    let avatarPath: String?
    let onToggleInspector: () -> Void
    @StateObject private var messagesViewModel: ChatMessagesViewModel

    @State private var draft: String = ""
    @State private var isPagingHistory: Bool = false
    @State private var loadingIndicatorVisible: Bool = false
    @State private var loadingIndicatorTask: Task<Void, Never>? = nil

    private let loadingIndicatorShowDelayNs: UInt64 = 0
    private let loadingIndicatorHideDelayNs: UInt64 = 120_000_000

    private var isTimelineLoading: Bool {
        messagesViewModel.isBootstrapping || store.isLoadingHistory || isPagingHistory
    }

    init(
        store: TelegramStore,
        chat: TGChat,
        avatarPath: String?,
        onToggleInspector: @escaping () -> Void
    ) {
        self.store = store
        self.chat = chat
        self.avatarPath = avatarPath
        self.onToggleInspector = onToggleInspector
        _messagesViewModel = StateObject(wrappedValue: ChatMessagesViewModel(store: store, chatId: chat.id))
    }

    @MainActor
    private func updateLoadingIndicatorVisibility(isLoading: Bool) {
        loadingIndicatorTask?.cancel()
        let delayNs = isLoading ? loadingIndicatorShowDelayNs : loadingIndicatorHideDelayNs
        loadingIndicatorTask = Task { @MainActor in
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                loadingIndicatorVisible = isLoading
            }
        }
    }

    @MainActor
    private func refreshToolbarLoadingIndicator() {
        updateLoadingIndicatorVisibility(isLoading: isTimelineLoading)
    }

    var body: some View {
        MessagesPane(
            store: store,
            chat: chat,
            viewModel: messagesViewModel,
            isPagingHistory: $isPagingHistory
        )
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
            }
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    ChatTitleButtonInline(
                        title: chat.title,
                        chatId: chat.id,
                        avatarPath: avatarPath
                    )
                    .onTapGesture {
                        onToggleInspector()
                    }

                    ZStack {
                        MacSpinningIndicator()
                            .frame(width: 14, height: 14)
                            .opacity(loadingIndicatorVisible ? 1 : 0)
                    }
                    .frame(width: 14, height: 14)
                }
                .padding(.top, headerDebug.resolvedToolbarOffsetY)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
            }
            .task(id: chat.id) {
                draft = ""
                refreshToolbarLoadingIndicator()
            }
            .onChange(of: messagesViewModel.isBootstrapping) { _, _ in
                refreshToolbarLoadingIndicator()
            }
            .onChange(of: store.isLoadingHistory) { _, _ in
                refreshToolbarLoadingIndicator()
            }
            .onChange(of: isPagingHistory) { _, _ in
                refreshToolbarLoadingIndicator()
            }
            .onDisappear {
                loadingIndicatorTask?.cancel()
                loadingIndicatorTask = nil
            }
    }
}

private struct MacSpinningIndicator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.usesThreadedAnimation = true
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.startAnimation(nil)
    }
}
