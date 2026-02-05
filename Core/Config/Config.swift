//
//  Config.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import Dispatch

enum Config {
    static var apiId: Int {
        Int(ProcessInfo.processInfo.environment["TELEGRAM_API_ID"] ?? "") ?? 0
    }

    static var apiHash: String {
        ProcessInfo.processInfo.environment["TELEGRAM_API_HASH"] ?? ""
    }
}

enum SwiftUIPublishTrace {
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

final class ViewUpdatePhaseTracker {
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
