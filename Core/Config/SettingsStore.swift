//
//  SettingsStore.swift
//  Aurora
//

import Foundation
import Combine

struct AISettingsSnapshot: Sendable {
    let baseURLString: String
    let apiKey: String
    let modelName: String
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var baseURLString: String {
        didSet {
            defaults.set(baseURLString, forKey: Keys.baseURLString)
        }
    }

    @Published var apiKey: String {
        didSet {
            defaults.set(apiKey, forKey: Keys.apiKey)
        }
    }

    @Published var modelName: String {
        didSet {
            defaults.set(modelName, forKey: Keys.modelName)
        }
    }

    @Published var aiContextMessageCount: Int {
        didSet {
            let clamped = Self.clampContextCount(aiContextMessageCount)
            if clamped != aiContextMessageCount {
                aiContextMessageCount = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.aiContextMessageCount)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURLString = defaults.string(forKey: Keys.baseURLString) ?? "http://127.0.0.1:1234"
        self.apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        self.modelName = defaults.string(forKey: Keys.modelName) ?? "local-model"
        self.aiContextMessageCount = Self.clampContextCount(defaults.object(forKey: Keys.aiContextMessageCount) as? Int ?? 10)
    }

    func aiSnapshot() -> AISettingsSnapshot {
        AISettingsSnapshot(
            baseURLString: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private enum Keys {
    static let baseURLString = "ai.base_url"
    static let apiKey = "ai.api_key"
    static let modelName = "ai.model_name"
    static let aiContextMessageCount = "ai.context_message_count"
}

private extension SettingsStore {
    static func clampContextCount(_ value: Int) -> Int {
        min(max(value, 1), 30)
    }
}
