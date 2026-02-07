//
//  Config.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import Dispatch

nonisolated enum Config {
    static var apiId: Int {
        Int(ProcessInfo.processInfo.environment["TELEGRAM_API_ID"] ?? "") ?? 0
    }

    static var apiHash: String {
        ProcessInfo.processInfo.environment["TELEGRAM_API_HASH"] ?? ""
    }
}

nonisolated enum SwiftUIPublishTrace {
#if DEBUG
    private static let enabledFlag: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["TRACE_SWIFTUI_PUBLISH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
    }()
    private static let startUptimeNs = DispatchTime.now().uptimeNanoseconds
    private static let lock = NSLock()
    private static var uiEventsCount = 0
    private static var publishCount = 0
    private static var storeEventsCount = 0
    private static var warningCandidatesCount = 0
#endif

    static var isEnabled: Bool {
#if DEBUG
        enabledFlag
#else
        false
#endif
    }

    static func uiEvent(name: String, chatId: Int64?, payload: String, reason: String) {
#if DEBUG
        guard enabledFlag else { return }
        lock.lock()
        uiEventsCount += 1
        lock.unlock()
        emit(kind: "UI_EVENT", fields: [
            "name=\(sanitize(name))",
            "chatId=\(chatIdValue(chatId))",
            "payload=\(sanitize(payload))",
            "reason=\(sanitize(reason))"
        ])
#endif
    }

    static func storeEvent(name: String, chatId: Int64?, details: String, reason: String) {
#if DEBUG
        guard enabledFlag else { return }
        lock.lock()
        storeEventsCount += 1
        lock.unlock()
        emit(kind: "STORE_EVENT", fields: [
            "name=\(sanitize(name))",
            "chatId=\(chatIdValue(chatId))",
            "details=\(sanitize(details))",
            "reason=\(sanitize(reason))"
        ])
#endif
    }

    static func publishVM(
        vm: String,
        property: String,
        chatId: Int64?,
        newCount: Int?,
        reason: String,
        isViewUpdating: Bool
    ) {
#if DEBUG
        guard enabledFlag else { return }
        lock.lock()
        publishCount += 1
        if isViewUpdating {
            warningCandidatesCount += 1
        }
        lock.unlock()

        let countText = newCount.map(String.init) ?? "-"
        emit(kind: "PUBLISH_VM", fields: [
            "vm=\(sanitize(vm))",
            "property=\(sanitize(property))",
            "chatId=\(chatIdValue(chatId))",
            "newCount=\(countText)",
            "reason=\(sanitize(reason))",
            "isViewUpdating=\(isViewUpdating)"
        ])
#endif
    }

    static func summary(warningsSeen: Int? = nil) -> String {
#if DEBUG
        guard enabledFlag else { return "" }
        lock.lock()
        let uiEvents = uiEventsCount
        let publishes = publishCount
        let warnings = warningsSeen ?? warningCandidatesCount
        lock.unlock()
        return "SWIFTUI-PUBLISH-TRACE SUMMARY warningsSeen=\(warnings) publishCount=\(publishes) uiEvents=\(uiEvents)"
#else
        return ""
#endif
    }

    static func emitSummary(warningsSeen: Int? = nil) {
#if DEBUG
        guard enabledFlag else { return }
        print(summary(warningsSeen: warningsSeen))
#endif
    }

#if DEBUG
    private static func emit(kind: String, fields: [String]) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs: UInt64
        if nowNs >= startUptimeNs {
            elapsedMs = (nowNs - startUptimeNs) / 1_000_000
        } else {
            elapsedMs = 0
        }
        let queueLabel = String(cString: __dispatch_queue_get_label(nil))
        let taskPriority = String(describing: Task.currentPriority)
        let parts = [
            "SWIFTUI-PUBLISH-TRACE",
            "timestampMs=\(elapsedMs)",
            kind
        ] + fields + [
            "threadMain=\(Thread.isMainThread)",
            "task=\(sanitize(taskPriority))",
            "queue=\(sanitize(queueLabel))"
        ]
        print(parts.joined(separator: " "))
    }

    private static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "-"
        }
        return trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func chatIdValue(_ chatId: Int64?) -> String {
        guard let chatId else { return "n/a" }
        return String(chatId)
    }
#endif
}

nonisolated enum HistoryTrace {
#if DEBUG
    private static let enabledFlag: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_HISTORY_TRACE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
    }()
    private static let chatIdFilter: Int64? = {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_HISTORY_TRACE_CHAT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Int64(raw)
        else { return nil }
        return value
    }()
    private static let lock = NSLock()
    private static var lastEmitMsByRateKey: [String: UInt64] = [:]
#endif

    static var isEnabled: Bool {
#if DEBUG
        enabledFlag
#else
        false
#endif
    }

    static func isEnabled(for chatId: Int64?) -> Bool {
#if DEBUG
        guard enabledFlag else { return false }
        guard let filter = chatIdFilter else { return true }
        guard let chatId else { return false }
        return chatId == filter
#else
        _ = chatId
        return false
#endif
    }

    static func emit(
        tag: String,
        chatId: Int64?,
        fields: [(String, String)],
        rateKey: String? = nil,
        rateLimitMs: UInt64 = 0
    ) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        if let rateKey, rateLimitMs > 0 {
            lock.lock()
            let last = lastEmitMsByRateKey[rateKey]
            if let last, nowMs >= last, (nowMs - last) < rateLimitMs {
                lock.unlock()
                return
            }
            lastEmitMsByRateKey[rateKey] = nowMs
            lock.unlock()
        }

        var parts: [String] = [
            "HISTORY_TRACE",
            "tag=\(sanitize(tag))",
            "chatId=\(chatId.map(String.init) ?? "null")"
        ]
        for (key, value) in fields {
            parts.append("\(sanitize(key))=\(sanitize(value))")
        }
        print(parts.joined(separator: " "))
#else
        _ = tag
        _ = chatId
        _ = fields
        _ = rateKey
        _ = rateLimitMs
#endif
    }

    static func boolValue(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    static func optionalInt64(_ value: Int64?) -> String {
        value.map(String.init) ?? "null"
    }

    static func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "null"
    }

    static func optionalDouble(_ value: Double?, decimals: Int = 2) -> String {
        guard let value else { return "null" }
        return String(format: "%.\(decimals)f", value)
    }

#if DEBUG
    private static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "null"
        }
        return trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: " ", with: "_")
    }
#endif
}

nonisolated final class ViewUpdatePhaseTracker: @unchecked Sendable {
    static let shared = ViewUpdatePhaseTracker()

    private let lock = NSLock()
    private var updateToken: UInt64 = 0
    private var isUpdatingFlag = false

    private init() {}

    var isViewUpdating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isUpdatingFlag
    }

    func markUpdating(source: String) {
#if DEBUG
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.markUpdating(source: source)
            }
            return
        }
        let token: UInt64
        lock.lock()
        updateToken &+= 1
        token = updateToken
        isUpdatingFlag = true
        lock.unlock()

        // Approximate end of current SwiftUI update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.updateToken == token else { return }
            self.isUpdatingFlag = false
        }
#else
        _ = source
#endif
    }
}
