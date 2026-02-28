//
//  ContentView.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit
import Combine

enum ChatLayoutMetrics {
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
    let store: TelegramStore
    @State private var inspectorShown: Bool = false
    @State private var listSelection: Int64? = nil
    @State private var isAuthorized: Bool = false
    @State private var hostWindow: NSWindow? = nil
    @State private var didApplyWindowChromeFix: Bool = false

    private var selectedChatIdForUI: Int64? {
        listSelection
    }

    private var sidebarSelectionBinding: Binding<Int64?> {
        Binding(
            get: { listSelection },
            set: { newChatId in
                let oldChatId = listSelection
                guard oldChatId != newChatId else { return }
                listSelection = newChatId
#if DEBUG
                PerfCounters.bumpEvent(
                    "ContentView.onChange.listSelection",
                    details: "old=\(oldChatId.map(String.init) ?? "nil") new=\(newChatId.map(String.init) ?? "nil")"
                )
#endif
                SwiftUIPublishTrace.uiEvent(
                    name: "onChange_selectedChat",
                    chatId: newChatId ?? oldChatId,
                    payload: "old=\(oldChatId.map(String.init) ?? "n/a") new=\(newChatId.map(String.init) ?? "n/a")",
                    reason: "fromSelectionChange"
                )
                guard let id = newChatId else { return }
                // Let List commit the visual selection before triggering store side effects.
                DispatchQueue.main.async {
                    store.selectChat(id)
                }
            }
        )
    }

    init(store: TelegramStore) {
        self.store = store
        _listSelection = State(initialValue: store.selectedChatId)
        _isAuthorized = State(initialValue: store.isAuthorized)
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

    @MainActor
    private func applyWindowChromeFixIfNeeded(window: NSWindow) {
        guard !didApplyWindowChromeFix else { return }
        didApplyWindowChromeFix = true

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none

        // macOS 26.0 titlebar rendering workaround:
        // force a second chrome pass after first layout.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion == 26 && os.minorVersion == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
                guard let window else { return }
                window.titlebarAppearsTransparent = false
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.styleMask.insert(.fullSizeContentView)
                window.titleVisibility = .hidden
                window.displayIfNeeded()
            }
        }
    }

    var body: some View {
#if DEBUG
        let _ = PerfCounters.isPrintChangesEnabled ? Self._printChanges() : ()
        let _ = PerfCounters.bumpRender(
            "ContentView.body",
            details: "selectedChatId=\(selectedChatIdForUI.map(String.init) ?? "nil") inspectorShown=\(inspectorShown) isAuthorized=\(isAuthorized)"
        )
#endif
        let minWindowWidth = inspectorShown
            ? max(ChatLayoutMetrics.baseWindowMinWidth, ChatLayoutMetrics.minWindowWidthWithInspector)
            : max(ChatLayoutMetrics.baseWindowMinWidth, ChatLayoutMetrics.minWindowWidthWithoutInspector)

        ZStack {
            ContentMainPaneView(
                store: store,
                selectedChatId: selectedChatIdForUI,
                listSelection: sidebarSelectionBinding,
                inspectorShown: $inspectorShown
            )
            .task {
#if DEBUG
                PerfCounters.bumpEvent(
                    "ContentView.task",
                    details: "selection=\(listSelection.map(String.init) ?? "nil") storeSelection=\(store.selectedChatId.map(String.init) ?? "nil")"
                )
#endif
                if listSelection == nil, let storeSelection = store.selectedChatId {
                    listSelection = storeSelection
                }
                if let id = listSelection {
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
            .onReceive(store.$selectedChatId.removeDuplicates()) { newChatId in
#if DEBUG
                PerfCounters.bumpEvent(
                    "ContentView.onReceive.storeSelectedChatId",
                    details: "new=\(newChatId.map(String.init) ?? "nil")"
                )
#endif
                guard listSelection != newChatId else { return }
                DispatchQueue.main.async {
                    guard listSelection != newChatId else { return }
                    listSelection = newChatId
                }
            }

            if !isAuthorized {
                ContentLoginOverlayView(store: store)
            }
        }
        .onReceive(store.$isAuthorized.removeDuplicates()) { nextAuthorized in
#if DEBUG
            PerfCounters.bumpEvent(
                "ContentView.onReceive.storeIsAuthorized",
                details: "isAuthorized=\(nextAuthorized)"
            )
#endif
            isAuthorized = nextAuthorized
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
                didApplyWindowChromeFix = false
                hostWindow = window
                Task { @MainActor in
                    applyWindowChromeFixIfNeeded(window: window)
                }
                ensureWindowMinSize(minWidth: minWindowWidth)
            }
        )
        .onAppear {
#if DEBUG
            PerfCounters.bumpEvent(
                "ContentView.onAppear",
                details: "inspectorShown=\(inspectorShown)"
            )
#endif
            ensureWindowMinSize(minWidth: minWindowWidth)
        }
        .onChange(of: inspectorShown) { _, newValue in
#if DEBUG
            PerfCounters.bumpEvent(
                "ContentView.onChange.inspectorShown",
                details: "shown=\(newValue)"
            )
#endif
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

private struct ContentViewPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview

    var body: some View {
        ContentView(store: store)
            .environmentObject(store)
            .frame(width: 980, height: 680)
    }
}

#Preview("ContentView") {
    ContentViewPreviewContainer()
}
