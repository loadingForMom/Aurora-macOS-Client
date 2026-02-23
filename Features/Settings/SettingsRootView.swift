//
//  SettingsRootView.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import SwiftUI
import AppKit

enum AuroraSettingsSection: String, CaseIterable, Identifiable {
    case general = "Общие"
    case notifications = "Уведомления и звук"
    case privacy = "Конфиденциальность"
    case data = "Данные и память"
    case sessions = "Активные сессии"
    case appearance = "Оформление"
    case language = "Язык"
    case stickers = "Стикеры и эмодзи"
    case folders = "Папки с чатами"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .notifications: return "bell"
        case .privacy: return "hand.raised"
        case .data: return "externaldrive"
        case .sessions: return "rectangle.stack.badge.person.crop"
        case .appearance: return "paintbrush"
        case .language: return "globe"
        case .stickers: return "face.smiling"
        case .folders: return "folder"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var store: TelegramStore
    @State private var selection: AuroraSettingsSection = .general
    @State private var sidebarSearch: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                SidebarProfileHeader(store: store)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .padding(.horizontal, 12)

                Divider().opacity(0.35)

                List(AuroraSettingsSection.allCases, selection: $selection) { sec in
                    Label(sec.rawValue, systemImage: sec.systemImage)
                        .tag(sec)
                }
                .searchable(text: $sidebarSearch, placement: .sidebar)
                .listStyle(.sidebar)
                .toolbar(removing: .sidebarToggle)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 280, max: 280)
        } detail: {
            NavigationStack {
                Group {
                    switch selection {
                    case .general:
                        GeneralSettingsView(store: store)
                    case .notifications:
                        NotificationsSettingsView()
                    case .privacy:
                        PrivacySettingsView(store: store)
                    case .data:
                        DataAndStorageSettingsView(store: store)
                    case .sessions:
                        PlaceholderSettingsView(title: "Активные сессии", items: [
                            "Это устройство (заглушка)",
                            "Активные сеансы (заглушка)",
                            "Автоматически завершать сеансы (заглушка)"
                        ])
                    case .appearance:
                        AppearanceSettingsView()
                    case .language:
                        PlaceholderSettingsView(title: "Язык", items: [
                            "Выбор языка (заглушка)"
                        ])
                    case .stickers:
                        PlaceholderSettingsView(title: "Стикеры и эмодзи", items: [
                            "Стикеры (заглушка)",
                            "Эмодзи (заглушка)"
                        ])
                    case .folders:
                        PlaceholderSettingsView(title: "Папки с чатами", items: [
                            "Управление папками (заглушка)"
                        ])
                    }
                }
                .navigationTitle(selection.rawValue)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            columnVisibility = .doubleColumn
        }
        .onChange(of: columnVisibility) { _, newValue in
            if newValue != .doubleColumn {
                columnVisibility = .doubleColumn
            }
        }
    }
}

private struct SidebarProfileHeader: View {
    @ObservedObject var store: TelegramStore

    var body: some View {
        let displayName = store.myDisplayName
        let initials = initialsFrom(displayName)

        // IMPORTANT:
        // store.myProfileNSImage теперь отдаёт уже миниатюру (через дисковый кэш),
        // а не “полный” decode исходника.
        let img = store.myProfileNSImage

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .glassEffect(in: Circle())
                    .frame(width: 36, height: 36)

                if let img {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName.isEmpty ? "—" : displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Text("Apple-style suffering, but TDLib-powered")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private func initialsFrom(_ name: String) -> String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }
        if parts.isEmpty { return "?" }
        return parts.joined()
    }
}

// MARK: - Panes

private struct GeneralSettingsView: View {
    @ObservedObject var store: TelegramStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @AppStorage("general_energy_saving") private var energySaving = false
    @AppStorage("general_spellcheck") private var spellcheck = true
    @AppStorage("general_interface_style") private var interfaceStyle = 0

    @State private var accountAction: AccountAction?

    private enum AccountAction: Identifiable {
        case logout
        case switchAccount

        var id: String {
            switch self {
            case .logout: return "logout"
            case .switchAccount: return "switchAccount"
            }
        }

        var title: String {
            switch self {
            case .logout: return "Выйти из аккаунта"
            case .switchAccount: return "Сменить аккаунт"
            }
        }

        var message: String {
            switch self {
            case .logout:
                return "Вы выйдете из текущего аккаунта Telegram на этом устройстве."
            case .switchAccount:
                return "Вы выйдете из текущего аккаунта, чтобы войти в другой."
            }
        }

        var confirmTitle: String {
            switch self {
            case .logout: return "Выйти"
            case .switchAccount: return "Сменить аккаунт"
            }
        }
    }

    var body: some View {
        Form {
            Section("Аккаунт") {
                LabeledContent("Текущий пользователь") {
                    Text(store.myDisplayName.isEmpty ? "—" : store.myDisplayName)
                        .foregroundStyle(.secondary)
                }

                Button("Сменить аккаунт") {
                    accountAction = .switchAccount
                }
                .disabled(!store.isAuthorized)

                Button("Выйти из аккаунта") {
                    accountAction = .logout
                }
                .disabled(!store.isAuthorized)
            }

            Section("Общие") {
                Toggle("Энергосбережение", isOn: $energySaving)
                Toggle("Грамматика и орфография", isOn: $spellcheck)
            }

            Section("Интерфейс") {
                Picker("Цветовая схема", selection: $interfaceStyle) {
                    Text("Системный").tag(0)
                    Text("Светлый").tag(1)
                    Text("Тёмный").tag(2)
                }
            }

            Section("AI (LM Studio)") {
                TextField("Base URL", text: $settingsStore.baseURLString)

                SecureField("API key (optional)", text: $settingsStore.apiKey)

                TextField("Model", text: $settingsStore.modelName)

                Stepper(value: $settingsStore.aiContextMessageCount, in: 1...30) {
                    LabeledContent("Сообщений в контексте") {
                        Text("\(settingsStore.aiContextMessageCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Endpoint: {Base URL}/v1/chat/completions")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Быстрый доступ") {
                Button("Сочетания клавиш (заглушка)") { }
            }

            Section("Продвинутые") {
                Button("Продвинутые настройки (заглушка)") { }
                Button("Действия Force Touch (заглушка)") { }
                Button("Отправка сообщений (заглушка)") { }
            }

            Section("Настройки звонков") {
                Button("Камера (заглушка)") { }
                Button("Микрофон (заглушка)") { }
                Button("Вывод (заглушка)") { }
            }
        }
        .alert("Аккаунт Telegram", isPresented: accountActionBinding) {
            if let action = accountAction {
                Button(action.confirmTitle, role: .destructive) {
                    store.logOut()
                    accountAction = nil
                }
            }
            Button("Отмена", role: .cancel) {
                accountAction = nil
            }
        } message: {
            if let action = accountAction {
                Text(action.message)
            }
        }
    }

    private var accountActionBinding: Binding<Bool> {
        Binding(
            get: { accountAction != nil },
            set: { newValue in
                if !newValue { accountAction = nil }
            }
        )
    }
}

private struct NotificationsSettingsView: View {
    @AppStorage("notif_enabled") private var enabled = true
    @AppStorage("notif_this_device") private var thisDevice = true
    @AppStorage("notif_sounds") private var sounds = true
    @AppStorage("notif_badge") private var badge = true
    @AppStorage("notif_when_active") private var whenActive = false

    var body: some View {
        Form {
            Section("Уведомления и звук") {
                Toggle("Уведомления", isOn: $enabled)
                Toggle("Принимать на этом устройстве", isOn: $thisDevice)
                Toggle("Звуковые эффекты", isOn: $sounds)
                Toggle("Счетчик на иконке", isOn: $badge)
                Toggle("Когда приложение активно", isOn: $whenActive)
            }
        }
    }
}

private struct PrivacySettingsView: View {
    @ObservedObject var store: TelegramStore

    private var pagination: TelegramStore.TDLibPaginationState<TelegramStore.BlockedSenderItem> {
        store.blockedSendersPagination
    }

    var body: some View {
        Form {
            Section("Заблокированные отправители") {
                if !store.isAuthorized {
                    Text("Доступно после входа в Telegram")
                        .foregroundStyle(.secondary)
                } else if pagination.items.isEmpty, pagination.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if pagination.items.isEmpty {
                    Text("Список пуст")
                        .foregroundStyle(.secondary)
                }

                ForEach(pagination.items) { item in
                    blockedRow(item)
                        .onAppear {
                            guard item.id == pagination.items.last?.id else { return }
                            _ = store.loadMoreBlockedSenders()
                        }
                }

                if pagination.isLoadingMore, !pagination.items.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }

                if let error = pagination.error, !error.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Повторить") {
                            _ = store.loadMoreBlockedSenders()
                        }
                    }
                    .padding(.vertical, 4)
                } else if !pagination.canLoadMore, !pagination.items.isEmpty {
                    Text("Больше нет записей")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            guard store.isAuthorized else { return }
            store.ensureBlockedSendersPaginationStarted()
        }
        .onChange(of: store.isAuthorized) { _, isAuthorized in
            if isAuthorized {
                store.ensureBlockedSendersPaginationStarted()
            }
        }
    }

    @ViewBuilder
    private func blockedRow(_ item: TelegramStore.BlockedSenderItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .user ? "person.crop.circle.fill" : "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(item.title)
                .lineLimit(1)

            Spacer()

            Text(item.kind == .user ? "Пользователь" : "Чат")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct DataAndStorageSettingsView: View {
    @ObservedObject var store: TelegramStore
    @AppStorage("cache_limit_mb") private var cacheLimitMB: Double = 2048

    @State private var didRequestInitialStats: Bool = false
    @State private var cacheLimitApplyTask: Task<Void, Never>? = nil

    private var categories: [TelegramStore.StorageBucket] {
        store.storageBuckets
    }

    private var cacheLimitBytes: Int64 {
        Int64(cacheLimitMB * 1024 * 1024)
    }

    private var canClearCache: Bool {
        store.clearableCacheBytes > 0
    }

    var body: some View {
        Form {
            Section("Использование памяти") {
                if !store.isAuthorized {
                    LabeledContent("Всего") {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Доступно после входа в Telegram")
                        Text("Завершите авторизацию, чтобы загрузить статистику и управлять кэшем.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button("Обновить статистику") { }
                        Button("Очистить кэш") { }
                            .disabled(true)
                    }
                    .disabled(true)
                } else if categories.isEmpty {
                    LabeledContent("Всего") {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Статистика ещё не загружена")
                        Text("Нажмите «Обновить статистику», чтобы получить реальные значения из TDLib.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button("Обновить статистику") {
                            Task { @MainActor in
                                store.refreshStorageStatistics()
                            }
                        }
                        Button("Очистить кэш") {
                            Task { @MainActor in
                                store.clearAllCache()
                            }
                        }
                        .disabled(!canClearCache)
                    }
                } else {
                    let total = categories.reduce(Int64(0)) { $0 + $1.bytes }
                    LabeledContent("Всего") {
                        Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .top, spacing: 18) {
                        DonutChart(values: categories.map(\.bytes))
                            .frame(width: 120, height: 120)
                            .padding(.vertical, 6)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(categories) { c in
                                HStack {
                                    Circle()
                                        .fill(.secondary.opacity(0.35))
                                        .frame(width: 10, height: 10)
                                    Text(c.title)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Обновить статистику") {
                            Task { @MainActor in
                                store.refreshStorageStatistics()
                            }
                        }
                        Button("Очистить кэш") {
                            Task { @MainActor in
                                store.clearAllCache()
                            }
                        }
                        .disabled(!canClearCache)
                    }

                    if !canClearCache {
                        Text("Сейчас очищать нечего: это в основном база данных сообщений, она не удаляется кнопкой очистки кэша.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Максимальный размер кэша")
                        Spacer()
                        Text("\(Int(cacheLimitMB)) MB")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $cacheLimitMB, in: 256...16384, step: 256)
                        .onChange(of: cacheLimitMB) { _, newValue in
                            cacheLimitApplyTask?.cancel()
                            cacheLimitApplyTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                let bytes = Int64(newValue * 1024 * 1024)
                                store.applyCacheLimitBytes(bytes)
                            }
                        }
                }
            }

            Section("Автоудаление закэшированных медиа") {
                Button("Настроить автоудаление (заглушка)") { }
            }

#if DEBUG
            Section("App DB (debug)") {
                Button("Print DB stats") {
                    store.printDatabaseStats()
                }

                if let stats = store.lastDatabaseStats {
                    LabeledContent("Chats") {
                        Text("\(stats.chats)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Messages") {
                        Text("\(stats.messages)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Users") {
                        Text("\(stats.users)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No stats yet. Tap the button to print counts to console.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
#endif
        }
        .task {
            guard !didRequestInitialStats else { return }
            guard store.isAuthorized else { return }
            didRequestInitialStats = true
            store.applyCacheLimitBytes(cacheLimitBytes)
            store.refreshStorageStatistics()
        }
        .onChange(of: store.isAuthorized) { _, isAuthorized in
            guard isAuthorized else { return }
            guard !didRequestInitialStats else { return }
            didRequestInitialStats = true
            Task { @MainActor in
                store.applyCacheLimitBytes(cacheLimitBytes)
                store.refreshStorageStatistics()
            }
        }
        .onDisappear {
            cacheLimitApplyTask?.cancel()
            cacheLimitApplyTask = nil
        }
    }
}

private struct AppearanceSettingsView: View {
    private enum InspectorLiquidDefaults {
        static let enabled = true
        static let glassStrength = 0.82
        static let tintStrength = 0.18
        static let posterBlur = 4.0
        static let actionsBlur = 1.2
        static let chromeOpacity = 0.92
    }

    @AppStorage("appearance_text_size") private var textSize: Double = 14
    @AppStorage("appearance_night_theme") private var nightTheme = false
    @AppStorage("inspector_liquid_enabled") private var inspectorLiquidEnabled = InspectorLiquidDefaults.enabled
    @AppStorage("inspector_liquid_glass_strength") private var inspectorLiquidGlassStrength = InspectorLiquidDefaults.glassStrength
    @AppStorage("inspector_liquid_tint_strength") private var inspectorLiquidTintStrength = InspectorLiquidDefaults.tintStrength
    @AppStorage("inspector_liquid_poster_blur") private var inspectorLiquidPosterBlur = InspectorLiquidDefaults.posterBlur
    @AppStorage("inspector_liquid_actions_blur") private var inspectorLiquidActionsBlur = InspectorLiquidDefaults.actionsBlur
    @AppStorage("inspector_liquid_chrome_opacity") private var inspectorLiquidChromeOpacity = InspectorLiquidDefaults.chromeOpacity

    var body: some View {
        Form {
            Section("Оформление") {
                HStack {
                    Text("Размер текста")
                    Spacer()
                    Text("\(Int(textSize))")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $textSize, in: 11...22, step: 1)
                Toggle("Смена темы ночью", isOn: $nightTheme)
            }

            Section("Liquid Glass (инспектор)") {
                Toggle("Нативное стекло в правом инспекторе", isOn: $inspectorLiquidEnabled)

                LiquidSettingSliderRow(
                    title: "Интенсивность стекла",
                    value: $inspectorLiquidGlassStrength,
                    range: 0...1.5,
                    step: 0.01,
                    fractionDigits: 2
                )
                .disabled(!inspectorLiquidEnabled)

                LiquidSettingSliderRow(
                    title: "Тонировка стекла",
                    value: $inspectorLiquidTintStrength,
                    range: 0...0.65,
                    step: 0.01,
                    fractionDigits: 2
                )
                .disabled(!inspectorLiquidEnabled)

                LiquidSettingSliderRow(
                    title: "Мягкость постера",
                    value: $inspectorLiquidPosterBlur,
                    range: 0...10,
                    step: 0.1,
                    fractionDigits: 1
                )
                .disabled(!inspectorLiquidEnabled)

                LiquidSettingSliderRow(
                    title: "Размытие действий",
                    value: $inspectorLiquidActionsBlur,
                    range: 0...3.5,
                    step: 0.05,
                    fractionDigits: 2
                )
                .disabled(!inspectorLiquidEnabled)

                LiquidSettingSliderRow(
                    title: "Прозрачность pinned chrome",
                    value: $inspectorLiquidChromeOpacity,
                    range: 0.25...1,
                    step: 0.01,
                    fractionDigits: 2
                )
                .disabled(!inspectorLiquidEnabled)

                Button("Сбросить параметры Liquid Glass") {
                    resetInspectorLiquidDefaults()
                }
            }
        }
    }

    private func resetInspectorLiquidDefaults() {
        inspectorLiquidEnabled = InspectorLiquidDefaults.enabled
        inspectorLiquidGlassStrength = InspectorLiquidDefaults.glassStrength
        inspectorLiquidTintStrength = InspectorLiquidDefaults.tintStrength
        inspectorLiquidPosterBlur = InspectorLiquidDefaults.posterBlur
        inspectorLiquidActionsBlur = InspectorLiquidDefaults.actionsBlur
        inspectorLiquidChromeOpacity = InspectorLiquidDefaults.chromeOpacity
    }
}

private struct LiquidSettingSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct PlaceholderSettingsView: View {
    let title: String
    let items: [String]

    var body: some View {
        Form {
            Section(title) {
                ForEach(items, id: \.self) { t in
                    Button(t) { }
                }
            }
        }
    }
}

private struct DonutChart: View {
    let values: [Int64]

    var body: some View {
        let total = max(values.reduce(0, +), 1)
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            let lineWidth: CGFloat = 18

            var start = -CGFloat.pi / 2
            for (idx, v) in values.enumerated() {
                let frac = CGFloat(v) / CGFloat(total)
                let end = start + frac * 2 * CGFloat.pi

                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)

                let shade = 0.25 + (CGFloat(idx % 6) * 0.08)
                ctx.stroke(path,
                           with: .color(Color.secondary.opacity(shade)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                start = end
            }

            var hole = Path()
            hole.addEllipse(in: rect.insetBy(dx: lineWidth, dy: lineWidth))
            ctx.fill(hole, with: .color(Color(nsColor: .windowBackgroundColor)))
        }
        .accessibilityHidden(true)
    }
}

private struct SettingsRootViewPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview
    @StateObject private var settingsStore = SettingsStore()

    var body: some View {
        SettingsRootView(store: store)
            .environmentObject(settingsStore)
            .frame(width: 980, height: 640)
    }
}

#Preview("SettingsRootView") {
    SettingsRootViewPreviewContainer()
}
