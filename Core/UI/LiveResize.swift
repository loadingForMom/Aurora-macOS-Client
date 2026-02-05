//
//  LiveResize.swift
//  Aurora
//
//  Created by Codex on 2/5/26.
//

import SwiftUI
import AppKit
import Combine

private struct LiveResizingKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// `true` while the containing `NSWindow` is in live resize (mouse held down on window edge).
    var isLiveResizing: Bool {
        get { self[LiveResizingKey.self] }
        set { self[LiveResizingKey.self] = newValue }
    }
}

final class LiveResizeState: ObservableObject {
    @Published var isLiveResizing: Bool = false
    @Published var frozenSnapshot: NSImage? = nil
}

/// Injects `EnvironmentValues.isLiveResizing` and freezes rendering during live resize by overlaying a snapshot.
struct BitmapLiveResizeModifier: ViewModifier {
    @StateObject private var state = LiveResizeState()

    func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(state.isLiveResizing ? 0 : 1)
                .animation(nil, value: state.isLiveResizing)

            if let img = state.frozenSnapshot {
                Image(nsImage: img)
                    .resizable(capInsets: .init(), resizingMode: .stretch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .allowsHitTesting(false)
            }
        }
        .environment(\.isLiveResizing, state.isLiveResizing)
        .background(
            WindowLiveResizeTracker(state: state)
                .frame(width: 0, height: 0)
        )
    }
}

extension View {
    /// During window live resize, AppKit preserves the current pixels and scales them,
    /// redrawing once at the end. Also exposes `isLiveResizing` to SwiftUI.
    func bitmapLiveResize() -> some View {
        modifier(BitmapLiveResizeModifier())
    }
}

private struct WindowLiveResizeTracker: NSViewRepresentable {
    @ObservedObject var state: LiveResizeState

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.state = state
        return v
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.state = state
        nsView.refreshConfiguration()
    }

    final class TrackingView: NSView {
        weak var state: LiveResizeState?
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshConfiguration()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== observedWindow {
                tearDownObservers()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func refreshConfiguration() {
            guard let window else { return }
            if window !== observedWindow {
                tearDownObservers()
                observedWindow = window
                setUpObservers(for: window)
            }
        }

        private func setUpObservers(for window: NSWindow) {
            let nc = NotificationCenter.default
            observers.append(
                nc.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.state?.frozenSnapshot = window.contentView.flatMap { self.snapshot(of: $0) }
                    self.state?.isLiveResizing = true
                }
            )
            observers.append(
                nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.state?.isLiveResizing = false
                    DispatchQueue.main.async { [weak self] in
                        self?.state?.frozenSnapshot = nil
                    }
                }
            )
        }

        private func snapshot(of view: NSView) -> NSImage? {
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            view.cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            return img
        }

        private func tearDownObservers() {
            let nc = NotificationCenter.default
            observers.forEach { nc.removeObserver($0) }
            observers.removeAll(keepingCapacity: true)
            observedWindow = nil
            state?.isLiveResizing = false
            state?.frozenSnapshot = nil
        }

        deinit {
            tearDownObservers()
        }
    }
}
