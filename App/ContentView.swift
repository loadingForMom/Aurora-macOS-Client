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
    @StateObject private var chatListViewModel: ChatListViewModel

    @State private var searchText: String = ""
    @State private var inspectorShown: Bool = false
    @State private var listSelection: Int64? = nil

    private func filteredChats(_ base: [TGChat], query: String) -> [TGChat] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }

        // NOTE: sidebar uses chat rows only, sourced from DB observation,
        // so it won't rerender on every message update.
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

    private var selectedChatIdForUI: Int64? {
        listSelection ?? store.selectedChatId
    }

    private var selectedChat: TGChat? {
        guard let chatId = selectedChatIdForUI else { return nil }
        return chatListViewModel.chats.first(where: { $0.id == chatId })
    }

    init(store: TelegramStore) {
        self.store = store
        _chatListViewModel = StateObject(wrappedValue: ChatListViewModel(dbPool: store.dbPool))
    }

    var body: some View {
        let baseChats = chatListViewModel.chats
        let chats = filteredChats(baseChats, query: searchText)

        ZStack {
            NavigationSplitView {
                List(selection: $listSelection) {
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
                        ChatScreen(
                            store: store,
                            chat: chat,
                            avatarPath: avatarPath(for: chat.id),
                            onToggleInspector: { inspectorShown.toggle() }
                        )
                            .id(chat.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toolbar(removing: .title)
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
                if listSelection == nil, let storeSelection = store.selectedChatId {
                    listSelection = storeSelection
                }
                if let id = listSelection ?? store.selectedChatId {
                    SwiftUIPublishTrace.uiEvent(
                        name: "task_restoreSelectedChat",
                        chatId: id,
                        payload: "chatId=\(id)",
                        reason: "fromSelectionChange"
                    )
                    DispatchQueue.main.async {
                        store.selectChat(id, forceReload: false)
                    }
                }
            }
            .onChange(of: listSelection) { oldChatId, newChatId in
                SwiftUIPublishTrace.uiEvent(
                    name: "onChange_selectedChat",
                    chatId: newChatId ?? oldChatId,
                    payload: "old=\(oldChatId.map(String.init) ?? "n/a") new=\(newChatId.map(String.init) ?? "n/a")",
                    reason: "fromSelectionChange"
                )
                guard let id = newChatId else { return }
                DispatchQueue.main.async {
                    store.selectChat(id)
                }
            }
            .onChange(of: store.selectedChatId) { _, newChatId in
                guard listSelection != newChatId else { return }
                DispatchQueue.main.async {
                    listSelection = newChatId
                }
            }

            if !store.isAuthorized {
                TelegramLoginView(store: store)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            store.flushDatabaseNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flushDatabaseNow()
            SwiftUIPublishTrace.emitSummary()
            AppSessionLogRecorder.shared.finalizeIfNeeded(reason: "NSApplication.willTerminateNotification")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            store.flushDatabaseNow()
        }
        .transaction { _ in
            ViewUpdatePhaseTracker.shared.markUpdating(source: "ContentView")
        }
    }
}

struct ChatTitleButtonInline: View {
    @EnvironmentObject private var store: TelegramStore

    let title: String
    let chatId: Int64
    let avatarPath: String?

    private var avatarRevision: String {
        let pathPart = avatarPath ?? "nil"
        let version = store.chatAvatarVersionByChatId[chatId] ?? 0
        return "\(pathPart)#\(version)"
    }

    var body: some View {
        HStack(spacing: 8) {
            AvatarCircle(
                title: title,
                identityKey: AvatarCacheKey(
                    kind: .chat,
                    id: chatId,
                    size: 28,
                    scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                    revision: avatarRevision
                ),
                reloadToken: avatarRevision,
                size: 28,
                font: .system(size: 11, weight: .semibold, design: .rounded),
                imageProvider: {
                    store.chatAvatarNSImage(chatId: chatId, pointSize: 28, preferHiRes: false)
                    ?? avatarPath.flatMap { DiskImageCache.shared.image(path: $0) }
                }
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

private struct TelegramLoginView: View {
    @ObservedObject var store: TelegramStore

    @State private var phoneNumber: String = ""
    @State private var authCode: String = ""
    @State private var password: String = ""

    @FocusState private var focusedField: Field?

    private enum Field {
        case phone
        case code
        case password
    }

    private enum AuthStep {
        case phone
        case code
        case password
        case other(title: String, message: String)
        case pending(message: String)
    }

    private var authStep: AuthStep {
        switch store.authState {
        case "authorizationStateWaitPhoneNumber":
            return .phone
        case "authorizationStateWaitCode":
            return .code
        case "authorizationStateWaitPassword":
            return .password
        case "authorizationStateWaitOtherDeviceConfirmation":
            return .other(
                title: "Подтверждение входа",
                message: "Подтвердите вход на другом устройстве в Telegram."
            )
        case "authorizationStateWaitTdlibParameters":
            return .pending(message: "Подготавливаем вход в Telegram…")
        case "authorizationStateLoggingOut":
            return .pending(message: "Выходим из аккаунта…")
        default:
            return .pending(message: "Подключаемся к Telegram…")
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Telegram")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Вход в аккаунт")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                loginContent
            }
            .padding(32)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(24)
        }
    }

    @ViewBuilder
    private var loginContent: some View {
        switch authStep {
        case .phone:
            VStack(alignment: .leading, spacing: 12) {
                Text("Введите номер телефона в международном формате.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("+7 999 123-45-67", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .phone)
                    .onSubmit {
                        submitPhoneIfPossible()
                    }

                Button("Отправить код") {
                    submitPhoneIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .code:
            VStack(alignment: .leading, spacing: 12) {
                Text("Введите код подтверждения из Telegram.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Код подтверждения", text: $authCode)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .code)
                    .onSubmit {
                        submitCodeIfPossible()
                    }

                Button("Подтвердить код") {
                    submitCodeIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitCode)
            }
        case .password:
            VStack(alignment: .leading, spacing: 12) {
                Text("Введите пароль двухэтапной аутентификации.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                SecureField("Пароль", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        submitPasswordIfPossible()
                    }

                Button("Войти") {
                    submitPasswordIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case let .other(title, message):
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        case let .pending(message):
            VStack(spacing: 10) {
                ProgressView()
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submitPhoneIfPossible() {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.submitPhoneNumber(trimmed)
    }

    private func submitCodeIfPossible() {
        guard let code = sanitizedAuthCode() else { return }
        store.submitAuthCode(code)
    }

    private func submitPasswordIfPossible() {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.submitAuthPassword(trimmed)
    }

    private var canSubmitCode: Bool {
        sanitizedAuthCode() != nil
    }

    private func sanitizedAuthCode() -> String? {
        let trimmed = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.allSatisfy({ $0.isNumber }) else { return nil }
        guard (3...8).contains(compact.count) else { return nil }
        return compact
    }
}
