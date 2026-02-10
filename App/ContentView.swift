//
//  ContentView.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit
import Combine

enum HeaderPlateStyle: String, CaseIterable, Identifiable {
    case systemGlass = "systemGlass"
    case ultraThinMaterial = "ultraThinMaterial"
    case thinMaterial = "thinMaterial"
    case regularMaterial = "regularMaterial"
    case thickMaterial = "thickMaterial"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemGlass:
            return "System Glass"
        case .ultraThinMaterial:
            return "Ultra Thin"
        case .thinMaterial:
            return "Thin"
        case .regularMaterial:
            return "Regular"
        case .thickMaterial:
            return "Thick"
        }
    }
}

final class ChatHeaderDebugState: ObservableObject {
    static let defaultAvatarSize: Double = 34
    static let defaultAvatarOverlap: Double = 3
    static let defaultAvatarLowering: Double = 8
    static let defaultToolbarOffsetY: Double = 6
    static let defaultInspectorGlassOffsetY: Double = 0
    static let defaultHeaderPlateOffsetX: Double = 0
    static let defaultHeaderPlateOffsetY: Double = 0
    static let defaultHeaderPlatePaddingX: Double = 14
    static let defaultHeaderPlatePaddingY: Double = 6
    static let defaultHeaderPlateCornerRadius: Double = 14
    static let defaultHeaderPlateStyle: HeaderPlateStyle = .systemGlass
    static let defaultHeaderPlateIntensity: Double = 0.38
    static let defaultHeaderPlateOpacity: Double = 0.78

    @Published var isEnabled: Bool = true
    @Published var avatarSize: Double = defaultAvatarSize
    @Published var avatarOverlap: Double = defaultAvatarOverlap
    @Published var avatarLowering: Double = defaultAvatarLowering
    @Published var toolbarOffsetY: Double = defaultToolbarOffsetY
    @Published var inspectorGlassOffsetY: Double = defaultInspectorGlassOffsetY
    @Published var headerPlateOffsetX: Double = defaultHeaderPlateOffsetX
    @Published var headerPlateOffsetY: Double = defaultHeaderPlateOffsetY
    @Published var headerPlatePaddingX: Double = defaultHeaderPlatePaddingX
    @Published var headerPlatePaddingY: Double = defaultHeaderPlatePaddingY
    @Published var headerPlateCornerRadius: Double = defaultHeaderPlateCornerRadius
    @Published var headerPlateStyleRawValue: String = defaultHeaderPlateStyle.rawValue
    @Published var headerPlateIntensity: Double = defaultHeaderPlateIntensity
    @Published var headerPlateOpacity: Double = defaultHeaderPlateOpacity

    var resolvedAvatarSize: CGFloat {
        CGFloat(isEnabled ? avatarSize : Self.defaultAvatarSize)
    }

    var resolvedAvatarOverlap: CGFloat {
        CGFloat(isEnabled ? avatarOverlap : Self.defaultAvatarOverlap)
    }

    var resolvedAvatarLowering: CGFloat {
        CGFloat(isEnabled ? avatarLowering : Self.defaultAvatarLowering)
    }

    var resolvedAvatarLift: CGFloat {
        max(0, resolvedAvatarSize - resolvedAvatarOverlap - resolvedAvatarLowering)
    }

    var resolvedToolbarOffsetY: CGFloat {
        CGFloat(isEnabled ? toolbarOffsetY : Self.defaultToolbarOffsetY)
    }

    var resolvedInspectorGlassOffsetY: CGFloat {
        CGFloat(isEnabled ? inspectorGlassOffsetY : Self.defaultInspectorGlassOffsetY)
    }

    var resolvedHeaderPlateOffsetX: CGFloat {
        CGFloat(isEnabled ? headerPlateOffsetX : Self.defaultHeaderPlateOffsetX)
    }

    var resolvedHeaderPlateOffsetY: CGFloat {
        CGFloat(isEnabled ? headerPlateOffsetY : Self.defaultHeaderPlateOffsetY)
    }

    var resolvedHeaderPlatePaddingX: CGFloat {
        CGFloat(isEnabled ? headerPlatePaddingX : Self.defaultHeaderPlatePaddingX)
    }

    var resolvedHeaderPlatePaddingY: CGFloat {
        CGFloat(isEnabled ? headerPlatePaddingY : Self.defaultHeaderPlatePaddingY)
    }

    var resolvedHeaderPlateCornerRadius: CGFloat {
        CGFloat(isEnabled ? headerPlateCornerRadius : Self.defaultHeaderPlateCornerRadius)
    }

    var resolvedHeaderPlateStyle: HeaderPlateStyle {
        .systemGlass
    }

    var resolvedHeaderPlateIntensity: Double {
        isEnabled ? headerPlateIntensity : Self.defaultHeaderPlateIntensity
    }

    var resolvedHeaderPlateOpacity: Double {
        isEnabled ? headerPlateOpacity : Self.defaultHeaderPlateOpacity
    }

    func reset() {
        avatarSize = Self.defaultAvatarSize
        avatarOverlap = Self.defaultAvatarOverlap
        avatarLowering = Self.defaultAvatarLowering
        toolbarOffsetY = Self.defaultToolbarOffsetY
        inspectorGlassOffsetY = Self.defaultInspectorGlassOffsetY
        headerPlateOffsetX = Self.defaultHeaderPlateOffsetX
        headerPlateOffsetY = Self.defaultHeaderPlateOffsetY
        headerPlatePaddingX = Self.defaultHeaderPlatePaddingX
        headerPlatePaddingY = Self.defaultHeaderPlatePaddingY
        headerPlateCornerRadius = Self.defaultHeaderPlateCornerRadius
        headerPlateStyleRawValue = Self.defaultHeaderPlateStyle.rawValue
        headerPlateIntensity = Self.defaultHeaderPlateIntensity
        headerPlateOpacity = Self.defaultHeaderPlateOpacity
    }
}

private enum ChatLayoutMetrics {
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarIdealWidth: CGFloat = 250
    static let sidebarMaxWidth: CGFloat = 320

    static let detailMinWidthNoInspector: CGFloat = 420
    static let detailMinWidthWithInspector: CGFloat = 620

    static let inspectorMinWidth: CGFloat = 280
    static let inspectorIdealWidth: CGFloat = 320
    static let inspectorMaxWidth: CGFloat = 420

    static let emptyInspectorMinWidth: CGFloat = 260
    static let emptyInspectorIdealWidth: CGFloat = 300
    static let emptyInspectorMaxWidth: CGFloat = 360

    static let baseWindowMinWidth: CGFloat = 780
    static let windowMinHeight: CGFloat = 620

    // Reserve extra space for split dividers/chrome between columns.
    static let splitChromeAllowanceNoInspector: CGFloat = 16
    static let splitChromeAllowanceWithInspector: CGFloat = 36

    static var minWindowWidthWithInspector: CGFloat {
        sidebarMinWidth + detailMinWidthWithInspector + inspectorMinWidth + splitChromeAllowanceWithInspector
    }

    static var minWindowWidthWithoutInspector: CGFloat {
        sidebarMinWidth + detailMinWidthNoInspector + splitChromeAllowanceNoInspector
    }
}

struct ContentView: View {
    @ObservedObject var store: TelegramStore
    @StateObject private var chatListViewModel: ChatListViewModel

    @State private var searchText: String = ""
    @State private var inspectorShown: Bool = false
    @State private var listSelection: Int64? = nil
    @State private var hostWindow: NSWindow? = nil

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

    @MainActor
    private func ensureWindowMinSize(minWidth: CGFloat) {
        guard let hostWindow else { return }

        let required = NSSize(width: minWidth, height: ChatLayoutMetrics.windowMinHeight)
        if hostWindow.minSize != required {
            hostWindow.minSize = required
        }

        var frame = hostWindow.frame
        let targetWidth = max(frame.width, required.width)
        let targetHeight = max(frame.height, required.height)
        guard targetWidth != frame.width || targetHeight != frame.height else { return }
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        hostWindow.setFrame(frame, display: true, animate: false)
    }

    var body: some View {
        let baseChats = chatListViewModel.chats
        let chats = filteredChats(baseChats, query: searchText)
        let detailMinWidth = inspectorShown
            ? ChatLayoutMetrics.detailMinWidthWithInspector
            : ChatLayoutMetrics.detailMinWidthNoInspector
        let minWindowWidth = inspectorShown
            ? max(ChatLayoutMetrics.baseWindowMinWidth, ChatLayoutMetrics.minWindowWidthWithInspector)
            : max(ChatLayoutMetrics.baseWindowMinWidth, ChatLayoutMetrics.minWindowWidthWithoutInspector)

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
                .navigationSplitViewColumnWidth(
                    min: ChatLayoutMetrics.sidebarMinWidth,
                    ideal: ChatLayoutMetrics.sidebarIdealWidth,
                    max: ChatLayoutMetrics.sidebarMaxWidth
                )
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
                .frame(
                    minWidth: detailMinWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
            .toolbar(removing: .title)
            .inspector(isPresented: $inspectorShown) {
                if let chat = selectedChat {
                    ChatInspectorView(chat: chat)
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
        .background(
            WindowResolutionView { window in
                guard hostWindow !== window else { return }
                hostWindow = window
                ensureWindowMinSize(minWidth: minWindowWidth)
            }
        )
        .onAppear {
            ensureWindowMinSize(minWidth: minWindowWidth)
        }
        .onChange(of: inspectorShown) { _, newValue in
            let requiredMinWidth = newValue
                ? max(ChatLayoutMetrics.baseWindowMinWidth, ChatLayoutMetrics.minWindowWidthWithInspector)
                : max(ChatLayoutMetrics.baseWindowMinWidth, ChatLayoutMetrics.minWindowWidthWithoutInspector)
            DispatchQueue.main.async {
                ensureWindowMinSize(minWidth: requiredMinWidth)
            }
        }
        .frame(minWidth: minWindowWidth, minHeight: ChatLayoutMetrics.windowMinHeight)
        .transaction { _ in
            ViewUpdatePhaseTracker.shared.markUpdating(source: "ContentView")
        }
    }
}

private struct WindowResolutionView: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

struct ChatTitleButtonInline: View {
    @EnvironmentObject private var store: TelegramStore
    @EnvironmentObject private var headerDebug: ChatHeaderDebugState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let title: String
    let chatId: Int64
    let avatarPath: String?

    private var avatarRevision: String {
        let pathPart = avatarPath ?? "nil"
        let version = store.chatAvatarVersionByChatId[chatId] ?? 0
        return "\(pathPart)#\(version)"
    }

    var body: some View {
        let avatarSize = headerDebug.resolvedAvatarSize
        let avatarLift = headerDebug.resolvedAvatarLift
        let plateOffsetX = headerDebug.resolvedHeaderPlateOffsetX
        let plateOffsetY = headerDebug.resolvedHeaderPlateOffsetY
        let platePaddingX = headerDebug.resolvedHeaderPlatePaddingX
        let platePaddingY = headerDebug.resolvedHeaderPlatePaddingY
        let plateCornerRadius = headerDebug.resolvedHeaderPlateCornerRadius
        let plateStyle = headerDebug.resolvedHeaderPlateStyle
        let plateIntensity = headerDebug.resolvedHeaderPlateIntensity
        let plateOpacity = headerDebug.resolvedHeaderPlateOpacity

        ZStack(alignment: .top) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, platePaddingX)
                .padding(.vertical, platePaddingY)
                .background {
                    HeaderTitlePlateBackground(
                        style: plateStyle,
                        cornerRadius: plateCornerRadius,
                        intensity: plateIntensity,
                        opacity: plateOpacity,
                        reduceTransparency: reduceTransparency
                    )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: plateCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .offset(x: plateOffsetX, y: plateOffsetY)

            AvatarCircle(
                title: title,
                identityKey: AvatarCacheKey(
                    kind: .chat,
                    id: chatId,
                    size: avatarSize,
                    scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                    revision: avatarRevision
                ),
                reloadToken: avatarRevision,
                size: avatarSize,
                font: .system(size: 11, weight: .semibold, design: .rounded),
                imageProvider: {
                    store.chatAvatarNSImage(chatId: chatId, pointSize: avatarSize, preferHiRes: false)
                    ?? avatarPath.flatMap { DiskImageCache.shared.image(path: $0) }
                }
            )
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .offset(y: -avatarLift)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }
}

private struct HeaderTitlePlateBackground: View {
    let style: HeaderPlateStyle
    let cornerRadius: CGFloat
    let intensity: Double
    let opacity: Double
    let reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
            } else {
                switch style {
                case .systemGlass:
                    Color.clear.glassEffect(in: shape)
                    shape.fill(.ultraThinMaterial).opacity(0.42 * intensity)
                case .ultraThinMaterial:
                    shape.fill(.ultraThinMaterial)
                case .thinMaterial:
                    shape.fill(.thinMaterial)
                case .regularMaterial:
                    shape.fill(.regularMaterial)
                case .thickMaterial:
                    shape.fill(.thickMaterial)
                }
            }

            shape.fill(Color.white.opacity(0.12 * intensity))
        }
        .opacity(opacity)
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
