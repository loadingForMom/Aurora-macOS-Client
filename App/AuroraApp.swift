//
//  AuroraApp.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit

@main
struct AuroraApp: App {
    @StateObject private var store: TelegramStore
    @StateObject private var chatHeaderDebugState: ChatHeaderDebugState

    init() {
        AppSessionLogRecorder.shared.startIfNeeded()
        _store = StateObject(wrappedValue: TelegramStore())
        _chatHeaderDebugState = StateObject(wrappedValue: ChatHeaderDebugState())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environmentObject(store)
                .environmentObject(chatHeaderDebugState)
#if DEBUG
                .onAppear {
                    ChatHeaderDebugWindowController.shared.showIfNeeded(state: chatHeaderDebugState)
                }
#endif
                .frame(minWidth: 780, minHeight: 620)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            InspectorCommands()
        }

        Settings {
            SettingsRootView(store: store)
                .environmentObject(store)
                .environmentObject(chatHeaderDebugState)
        }
        // Xcode-style: settings is a fixed panel sized to its content.
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)
    }
}

#if DEBUG
@MainActor
private final class ChatHeaderDebugWindowController {
    static let shared = ChatHeaderDebugWindowController()

    private var window: NSWindow?

    func showIfNeeded(state: ChatHeaderDebugState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = ChatHeaderDebugPanel()
            .environmentObject(state)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Chat Header Debug"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 360, height: 620))
        window.minSize = NSSize(width: 340, height: 560)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}

private struct ChatHeaderDebugPanel: View {
    @EnvironmentObject private var debug: ChatHeaderDebugState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Chat Header Debug")
                    .font(.headline)

                Toggle("Enable Overrides", isOn: $debug.isEnabled)

                Group {
                    SliderRow(title: "Glass Intensity", value: $debug.headerPlateIntensity, range: 0...1.5, step: 0.01, fractionDigits: 2)
                    SliderRow(title: "Glass Opacity", value: $debug.headerPlateOpacity, range: 0.15...1, step: 0.01, fractionDigits: 2)
                    SliderRow(title: "Avatar Size", value: $debug.avatarSize, range: 24...80, step: 1)
                    SliderRow(title: "Avatar Overlap", value: $debug.avatarOverlap, range: -12...20, step: 1)
                    SliderRow(title: "Avatar Lowering", value: $debug.avatarLowering, range: -20...30, step: 1)
                    SliderRow(title: "Header Offset Y", value: $debug.toolbarOffsetY, range: -20...90, step: 1)
                    SliderRow(title: "Inspector Glass Y", value: $debug.inspectorGlassOffsetY, range: -120...120, step: 1)
                    SliderRow(title: "Plate Offset X", value: $debug.headerPlateOffsetX, range: -200...200, step: 1)
                    SliderRow(title: "Plate Offset Y", value: $debug.headerPlateOffsetY, range: -120...120, step: 1)
                    SliderRow(title: "Plate Padding X", value: $debug.headerPlatePaddingX, range: 6...40, step: 1)
                    SliderRow(title: "Plate Padding Y", value: $debug.headerPlatePaddingY, range: 2...20, step: 1)
                    SliderRow(title: "Plate Corner", value: $debug.headerPlateCornerRadius, range: 8...32, step: 1)
                }
                .disabled(!debug.isEnabled)

                HStack {
                    Button("Reset Defaults") {
                        debug.reset()
                    }
                    Spacer()
                    Text("lift \(Int(debug.resolvedAvatarLift))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var fractionDigits: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if fractionDigits == 0 {
                    Text("\(Int(value))")
                        .font(.caption.monospacedDigit())
                } else {
                    Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                        .font(.caption.monospacedDigit())
                }
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
#endif
