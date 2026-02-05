//
//  TDLibUpdateProcessor.swift
//  Aurora
//

import Foundation
import OSLog
import Dispatch

actor TDLibUpdateProcessor {
    private let log = Logger(subsystem: "com.aurora.app", category: "tdlib.processor")
    private unowned let store: TelegramStore
    private var routedCount = 0
    private var updateCount = 0
    private var responseCount = 0
    private let startedAtNs = DispatchTime.now().uptimeNanoseconds

    init(store: TelegramStore) {
        self.store = store
    }

    func start(stream: AsyncStream<String>) {
#if DEBUG
        let queueLabel = String(cString: __dispatch_queue_get_label(nil))
        log.debug("tdlib processor start queue=\(queueLabel, privacy: .public) main=\(Thread.isMainThread, privacy: .public)")
#endif
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
        routedCount += 1
        if type.hasPrefix("update") {
            updateCount += 1
            await store.handleUpdate(json)
        } else {
            responseCount += 1
            await store.handleResponse(json)
        }
#if DEBUG
        if routedCount % 500 == 0 {
            let elapsedSec = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000_000.0
            let rate = elapsedSec > 0 ? Double(routedCount) / elapsedSec : 0
            let routed = routedCount
            let updates = updateCount
            let responses = responseCount
            log.debug(
                "tdlib processor routed=\(routed, privacy: .public) updates=\(updates, privacy: .public) responses=\(responses, privacy: .public) ratePerSec=\(rate, privacy: .public)"
            )
        }
#endif
    }

    private func extractType(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["@type"] as? String else { return nil }
        return type
    }
}
