//
//  AuroraApp.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

@main
struct AuroraApp: App {
    @StateObject private var store: TelegramStore
    @StateObject private var settingsStore: SettingsStore

    init() {
        let isPreview = ProcessInfo.isRunningForPreviews
        if !isPreview {
            Env.loadIfNeeded()
        }

        let storeMode: TelegramStore.Mode = isPreview ? .preview : .live
        _store = StateObject(wrappedValue: TelegramStore(mode: storeMode))
        _settingsStore = StateObject(wrappedValue: SettingsStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environmentObject(store)
                .environmentObject(settingsStore)
                .frame(minWidth: 780, minHeight: 620)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowBackgroundDragBehavior(.enabled)
        .commands {
            InspectorCommands()
        }

        Settings {
            SettingsRootView(store: store)
                .environmentObject(store)
                .environmentObject(settingsStore)
        }
        // Xcode-style: settings is a fixed panel sized to its content.
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)
    }
}
