//
//  AuroraApp.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

@main
struct AuroraApp: App {
    @StateObject private var store = TelegramStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .environmentObject(store)
                .bitmapLiveResize()
        }
        .commands {
            InspectorCommands()
        }

        Settings {
            SettingsRootView(store: store)
                .environmentObject(store)
        }
        // Xcode-style: settings is a fixed panel sized to its content.
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)
    }
}
