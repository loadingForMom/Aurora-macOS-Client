//
//  TDLibUpdateProcessor.swift
//  Aurora
//

import Foundation
import OSLog

actor TDLibUpdateProcessor {
    private let log = Logger(subsystem: "com.aurora.app", category: "tdlib.processor")
    private unowned let store: TelegramStore

    init(store: TelegramStore) {
        self.store = store
    }

    func start(stream: AsyncStream<String>) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for await json in stream {
                await self.route(json)
            }
        }
    }

    private func route(_ json: String) async {
        guard let type = extractType(json) else {
            log.debug("dropped tdlib payload with missing type")
            return
        }
        if type.hasPrefix("update") {
            await store.handleUpdate(json)
        } else {
            await store.handleResponse(json)
        }
    }

    private func extractType(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["@type"] as? String else { return nil }
        return type
    }
}
