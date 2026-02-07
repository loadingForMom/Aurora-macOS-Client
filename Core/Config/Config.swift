//
//  Config.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import Dispatch
import AppKit
import OSLog

final class AppSessionLogRecorder {
    static let shared = AppSessionLogRecorder()

    private struct StreamCapture {
        let name: String
        let targetFD: Int32
        let originalFD: Int32
        let readFD: Int32
        let source: DispatchSourceRead
    }

    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "com.aurora.app.session-log.capture")
    private var captures: [StreamCapture] = []
    private var started = false
    private var finalized = false
    private var sessionStartDate = Date()
    private var tempLogURL: URL?
    private var tempHandle: FileHandle?
    private var logsDirectoryURL: URL?

    private init() {}

    func startIfNeeded() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        sessionStartDate = Date()
        finalized = false
        lock.unlock()

        setupSessionStorage()
        setupCapture(name: "stdout", targetFD: STDOUT_FILENO)
        setupCapture(name: "stderr", targetFD: STDERR_FILENO)
    }

    func finalizeIfNeeded(reason: String) {
        lock.lock()
        if !started || finalized {
            lock.unlock()
            return
        }
        finalized = true
        lock.unlock()

        fflush(nil)
        teardownCaptures()

        captureQueue.sync {
            if let handle = tempHandle {
                try? handle.synchronize()
                try? handle.close()
                tempHandle = nil
            }
        }

        let endDate = Date()
        let destinationURL = makeFinalLogURL(endDate: endDate)
        let rawStreamText = loadRawStreamLog()
        let osLogText = loadOSLogDump(startDate: sessionStartDate, endDate: endDate)
        let metadata = makeMetadata(reason: reason, startDate: sessionStartDate, endDate: endDate)
        let payload = metadata + "\n\n===== STREAM (stdout+stderr) =====\n" + rawStreamText + "\n\n===== OSLOG =====\n" + osLogText + "\n"

        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: destinationURL, atomically: true, encoding: .utf8)
            print("Session logs saved: \(destinationURL.path)")
        } catch {
            print("Failed to write session logs to \(destinationURL.path): \(error)")
        }

        if let tempURL = tempLogURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func setupSessionStorage() {
        let logsDirectory = Self.resolveLogsDirectory()
        logsDirectoryURL = logsDirectory
        print("AppSessionLogRecorder logsDirectory=\(logsDirectory.path)")
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let tempName = ".active-\(Self.fileTimestamp(Date()))-\(ProcessInfo.processInfo.processIdentifier).log"
            let tempURL = logsDirectory.appendingPathComponent(tempName, isDirectory: false)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            tempLogURL = tempURL
            tempHandle = try FileHandle(forWritingTo: tempURL)
            captureQueue.async { [weak self] in
                guard let self else { return }
                self.writeChunk("[session-start] \(Self.isoDate(self.sessionStartDate)) pid=\(ProcessInfo.processInfo.processIdentifier)\n")
            }
        } catch {
            print("Failed to initialize session temp log file in \(logsDirectory.path): \(error)")
        }
    }

    private func setupCapture(name: String, targetFD: Int32) {
        let originalFD = dup(targetFD)
        guard originalFD >= 0 else {
            print("Failed to dup fd \(targetFD) for \(name)")
            return
        }

        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            print("Failed to create pipe for \(name)")
            close(originalFD)
            return
        }

        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]

        guard dup2(writeFD, targetFD) >= 0 else {
            print("Failed to redirect \(name)")
            close(readFD)
            close(writeFD)
            close(originalFD)
            return
        }
        close(writeFD)

        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: captureQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(readFD, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer.prefix(bytesRead))
                self.writeData(data)
                _ = data.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                    var sent = 0
                    while sent < bytesRead {
                        let n = write(originalFD, base.advanced(by: sent), bytesRead - sent)
                        if n <= 0 {
                            break
                        }
                        sent += n
                    }
                    return sent
                }
            } else {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(readFD)
        }
        source.resume()

        lock.lock()
        captures.append(StreamCapture(name: name, targetFD: targetFD, originalFD: originalFD, readFD: readFD, source: source))
        lock.unlock()
    }

    private func teardownCaptures() {
        lock.lock()
        let activeCaptures = captures
        captures.removeAll()
        lock.unlock()

        for capture in activeCaptures {
            capture.source.cancel()
            _ = dup2(capture.originalFD, capture.targetFD)
            close(capture.originalFD)
            writeChunk("[capture-stop] stream=\(capture.name)\n")
        }
    }

    private func writeData(_ data: Data) {
        guard let handle = tempHandle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("Failed to append stream chunk: \(error)")
        }
    }

    private func writeChunk(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        writeData(data)
    }

    private func loadRawStreamLog() -> String {
        guard let tempLogURL else { return "[stream log unavailable]" }
        guard let data = try? Data(contentsOf: tempLogURL) else {
            return "[failed to read stream log at \(tempLogURL.path)]"
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return data.base64EncodedString()
    }

    private func loadOSLogDump(startDate: Date, endDate: Date) -> String {
        guard #available(macOS 12.0, *) else {
            return "[OSLogStore unavailable on this macOS version]"
        }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: startDate.addingTimeInterval(-1.0))
            let entries = try store.getEntries(at: position)
            var lines: [String] = []
            lines.reserveCapacity(1024)
            let maxLines = 80_000

            for case let entry as OSLogEntryLog in entries {
                if entry.date > endDate {
                    break
                }
                let line = "[\(Self.isoDate(entry.date))] [\(entry.level.shortName)] [\(entry.subsystem):\(entry.category)] \(entry.composedMessage)"
                lines.append(line)
                if lines.count >= maxLines {
                    lines.append("[truncated] reached \(maxLines) OSLog lines")
                    break
                }
            }

            if lines.isEmpty {
                return "[no OSLog entries for current process in this session]"
            }
            return lines.joined(separator: "\n")
        } catch {
            return "[failed to read OSLogStore: \(error)]"
        }
    }

    private func makeFinalLogURL(endDate: Date) -> URL {
        let logsDirectory = logsDirectoryURL ?? Self.resolveLogsDirectory()
        let fileName = "log-\(Self.fileTimestamp(endDate))-\(ProcessInfo.processInfo.processIdentifier).txt"
        return logsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func makeMetadata(reason: String, startDate: Date, endDate: Date) -> String {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let bundleId = bundle.bundleIdentifier ?? "unknown"
        let os = process.operatingSystemVersionString
        let cwd = FileManager.default.currentDirectoryPath
        let logDir = logsDirectoryURL?.path ?? Self.resolveLogsDirectory().path
        let duration = max(0, endDate.timeIntervalSince(startDate))

        return [
            "Aurora Session Log",
            "bundleId: \(bundleId)",
            "version: \(appVersion) (\(build))",
            "pid: \(process.processIdentifier)",
            "start: \(Self.isoDate(startDate))",
            "end: \(Self.isoDate(endDate))",
            "durationSec: \(String(format: "%.3f", duration))",
            "terminationReason: \(reason)",
            "os: \(os)",
            "cwd: \(cwd)",
            "logsDirectory: \(logDir)"
        ].joined(separator: "\n")
    }

    private static func resolveLogsDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let customDir = env["AURORA_LOG_DIR"], !customDir.isEmpty {
            return URL(fileURLWithPath: customDir, isDirectory: true)
        }
        if let root = env["AURORA_PROJECT_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Logs", isDirectory: true)
        }

        var sourceURL = URL(fileURLWithPath: #filePath)
        sourceURL.deleteLastPathComponent()
        while sourceURL.path != "/" {
            let xcodeproj = sourceURL.appendingPathComponent("Aurora.xcodeproj", isDirectory: true)
            if FileManager.default.fileExists(atPath: xcodeproj.path) {
                return sourceURL.appendingPathComponent("Logs", isDirectory: true)
            }
            sourceURL.deleteLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}

@available(macOS 12.0, *)
private extension OSLogEntryLog.Level {
    var shortName: String {
        switch self {
        case .undefined:
            return "undefined"
        case .debug:
            return "debug"
        case .info:
            return "info"
        case .notice:
            return "notice"
        case .error:
            return "error"
        case .fault:
            return "fault"
        @unknown default:
            return "unknown"
        }
    }
}

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
