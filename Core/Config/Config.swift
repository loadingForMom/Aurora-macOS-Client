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
import os.signpost

extension ProcessInfo {
    nonisolated static var isRunningForPreviews: Bool {
        processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

nonisolated enum Env {
    private static let lock = NSLock()
    private static var didLoad = false

    static func loadIfNeeded() {
        if ProcessInfo.isRunningForPreviews {
            return
        }

        lock.lock()
        if didLoad {
            lock.unlock()
            return
        }
        didLoad = true
        lock.unlock()

        let env = ProcessInfo.processInfo.environment
        guard let path = resolveEnvFilePath(from: env) else {
            return
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Env.loadIfNeeded: failed to read env file at \(path)")
            return
        }

        for rawLine in content.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separatorIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            var value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2 {
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                    (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
            }
            // Keep explicitly provided non-empty values (e.g. shell export) as source of truth.
            if let existing = getenv(key), existing.pointee != 0 {
                continue
            }
            setenv(key, value, 1)
        }
    }

    private static func resolveEnvFilePath(from env: [String: String]) -> String? {
        if let explicitPath = env["ENV_FILE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty,
           let resolvedExplicitPath = existingPath(for: explicitPath) {
            return resolvedExplicitPath
        }

        if let root = env["AURORA_PROJECT_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !root.isEmpty {
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("Aurora.env", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let candidate = findAuroraEnv(startingAt: cwd) {
            return candidate.path
        }

        var sourceURL = URL(fileURLWithPath: #filePath)
        sourceURL.deleteLastPathComponent()
        if let candidate = findAuroraEnv(startingAt: sourceURL) {
            return candidate.path
        }

        return nil
    }

    private static func existingPath(for rawPath: String) -> String? {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }
        return expandedPath
    }

    private static func findAuroraEnv(startingAt startingURL: URL) -> URL? {
        var url = startingURL
        while true {
            let candidate = url.appendingPathComponent("Aurora.env", isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            if url.path == "/" {
                return nil
            }
            url.deleteLastPathComponent()
        }
    }
}

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

nonisolated enum PerfCounters {
#if DEBUG
    private static let enabledDefaultsKey = "debug.ui.perf.enabled"
    private static let printChangesDefaultsKey = "debug.ui.perf.printChanges"
    private static let enabledEnvDefault = parseBoolEnv("DEBUG_UI_PERF")
    private static let printChangesEnvDefault = parseBoolEnv("DEBUG_UI_PERF_PRINT_CHANGES")
    private static let emitEveryCount = 25
    private static let emitIntervalNs: UInt64 = 1_000_000_000
    private static let logger = Logger(subsystem: "com.aurora.app", category: "ui.perf")
    private static let signpostLog = OSLog(subsystem: "com.aurora.app", category: "points_of_interest")
    private static let lock = NSLock()
    private static var countsByKey: [String: Int] = [:]
    private static var lastLoggedNsByKey: [String: UInt64] = [:]
#endif

    static var isEnabled: Bool {
#if DEBUG
        boolSetting(for: enabledDefaultsKey, fallback: enabledEnvDefault)
#else
        false
#endif
    }

    static var isPrintChangesEnabled: Bool {
#if DEBUG
        boolSetting(for: printChangesDefaultsKey, fallback: printChangesEnvDefault)
#else
        false
#endif
    }

    static func setEnabled(_ enabled: Bool) {
#if DEBUG
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
        logger.debug("perf counters enabled=\(enabled, privacy: .public)")
#else
        _ = enabled
#endif
    }

    static func setPrintChangesEnabled(_ enabled: Bool) {
#if DEBUG
        UserDefaults.standard.set(enabled, forKey: printChangesDefaultsKey)
        logger.debug("perf printChanges enabled=\(enabled, privacy: .public)")
#else
        _ = enabled
#endif
    }

    @discardableResult
    static func bumpRender(
        _ key: StaticString,
        details: @autoclosure () -> String? = nil
    ) -> Int {
#if DEBUG
        bump(kind: "render", key: key, details: details)
#else
        _ = key
        _ = details
        return 0
#endif
    }

    @discardableResult
    static func bumpEvent(
        _ key: StaticString,
        details: @autoclosure () -> String? = nil
    ) -> Int {
#if DEBUG
        bump(kind: "event", key: key, details: details)
#else
        _ = key
        _ = details
        return 0
#endif
    }

    static func emitPOIEvent(_ name: StaticString, chatId: Int64? = nil) {
#if DEBUG
        guard isEnabled else { return }
        if let chatId {
            os_signpost(.event, log: signpostLog, name: name, "chatId=%{public}lld", chatId)
        } else {
            os_signpost(.event, log: signpostLog, name: name)
        }
#else
        _ = name
        _ = chatId
#endif
    }

    static func beginPOI(_ name: StaticString, chatId: Int64? = nil) -> OSSignpostID {
#if DEBUG
        guard isEnabled else { return .invalid }
        let signpostId = OSSignpostID(log: signpostLog)
        if let chatId {
            os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostId, "chatId=%{public}lld", chatId)
        } else {
            os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostId)
        }
        return signpostId
#else
        _ = name
        _ = chatId
        return .invalid
#endif
    }

    static func endPOI(_ name: StaticString, signpostId: OSSignpostID, chatId: Int64? = nil) {
#if DEBUG
        guard isEnabled else { return }
        guard signpostId != .invalid else { return }
        if let chatId {
            os_signpost(.end, log: signpostLog, name: name, signpostID: signpostId, "chatId=%{public}lld", chatId)
        } else {
            os_signpost(.end, log: signpostLog, name: name, signpostID: signpostId)
        }
#else
        _ = name
        _ = signpostId
        _ = chatId
#endif
    }

#if DEBUG
    private static func bump(kind: String, key: StaticString, details: () -> String?) -> Int {
        guard isEnabled else { return 0 }
        let fullKey = "\(kind).\(String(describing: key))"
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let count = (countsByKey[fullKey] ?? 0) + 1
        countsByKey[fullKey] = count
        let lastLoggedNs = lastLoggedNsByKey[fullKey] ?? 0
        let thresholdReached = count == 1 || count.isMultiple(of: emitEveryCount)
        let intervalReached = lastLoggedNs == 0 || (nowNs &- lastLoggedNs) >= emitIntervalNs
        let shouldLog = thresholdReached && intervalReached
        if shouldLog {
            lastLoggedNsByKey[fullKey] = nowNs
        }
        lock.unlock()

        guard shouldLog else { return count }
        let detailsText = details() ?? "none"
        logger.debug(
            "perf-counter key=\(fullKey, privacy: .public) count=\(count, privacy: .public) details=\(sanitize(detailsText), privacy: .public)"
        )
        return count
    }

    private static func boolSetting(for defaultsKey: String, fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else {
            return fallback
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    private static func parseBoolEnv(_ key: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return false }
        return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
#endif
}

nonisolated enum ChatPerfTrace {
#if DEBUG
    private static let enabledFlag: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_CHAT_PERF"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return false }
        return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
    }()
    private static let chatIdFilter: Int64? = {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_CHAT_PERF_CHAT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Int64(raw)
        else { return nil }
        return value
    }()
    private static let signpostLog = OSLog(subsystem: "com.aurora.app", category: "points_of_interest")
    private static let mediaTraceLog = Logger(subsystem: "com.aurora.app", category: "chat.media.trace")
    private static let collector: ChatPerfTraceCollector? = enabledFlag
        ? ChatPerfTraceCollector(chatIdFilter: chatIdFilter)
        : nil
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

    static func elapsedMs(since startUptimeNs: UInt64) -> Double {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        return Double(nowNs &- startUptimeNs) / 1_000_000
    }

    static func recordSnapshotReceived(chatId: Int64) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordSnapshotReceived()
#else
        _ = chatId
#endif
    }

    static func recordSnapshotApplied(chatId: Int64) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordSnapshotApplied()
#else
        _ = chatId
#endif
    }

    static func recordRowsBuild(chatId: Int64, isIncremental: Bool, durationMs: Double) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordRowsBuild(isIncremental: isIncremental, durationMs: durationMs)
#else
        _ = chatId
        _ = isIncremental
        _ = durationMs
#endif
    }

    static func recordContentOnlyFastPath(chatId: Int64) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordContentOnlyFastPath()
#else
        _ = chatId
#endif
    }

    static func recordScrollState(chatId: Int64, isScrolling: Bool) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordScrollState(isScrolling)
#else
        _ = chatId
        _ = isScrolling
#endif
    }

    static func recordHeavyEffectsDisabled(chatId: Int64, count: Int = 1) {
#if DEBUG
        guard count > 0 else { return }
        guard isEnabled(for: chatId) else { return }
        collector?.recordHeavyEffectsDisabled(count)
#else
        _ = chatId
        _ = count
#endif
    }

    static func shouldCoalesceLatest(chatId: Int64?) -> Bool {
#if DEBUG
        guard isEnabled(for: chatId) else { return false }
        return collector?.shouldCoalesceLatest() ?? false
#else
        _ = chatId
        return false
#endif
    }

    static func recordApplyWindowMessages(chatId: Int64, durationMs: Double) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordApplyWindowMessages(durationMs)
#else
        _ = chatId
        _ = durationMs
#endif
    }

    static func recordTextRender(chatId: Int64, durationMs: Double, cacheHit: Bool) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordTextRender(durationMs, cacheHit: cacheHit)
#else
        _ = chatId
        _ = durationMs
        _ = cacheHit
#endif
    }

    static func recordAvatarThumb(chatId: Int64?, durationMs: Double) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordAvatarThumb(durationMs)
#else
        _ = chatId
        _ = durationMs
#endif
    }

    static func recordMediaThumbRequest(chatId: Int64) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordMediaThumbRequest()
#else
        _ = chatId
#endif
    }

    static func recordMediaThumbCacheHit(chatId: Int64, cacheHit: Bool) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordMediaThumbCacheLookup(cacheHit: cacheHit)
#else
        _ = chatId
        _ = cacheHit
#endif
    }

    static func recordMediaDecode(chatId: Int64, durationMs: Double) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        collector?.recordMediaDecode(durationMs)
#else
        _ = chatId
        _ = durationMs
#endif
    }

    static func recordMediaSelection(
        chatId: Int64,
        messageId: Int64,
        targetWidthPx: Int,
        targetHeightPx: Int,
        selectedWidthPx: Int,
        selectedHeightPx: Int,
        isThumb: Bool,
        isUpgraded: Bool
    ) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        let line = [
            "MEDIA_TRACE",
            "chatId=\(chatId)",
            "messageId=\(messageId)",
            "targetPx=\(targetWidthPx)x\(targetHeightPx)",
            "selectedSizePx=\(selectedWidthPx)x\(selectedHeightPx)",
            "isThumb=\(isThumb ? "true" : "false")",
            "isUpgraded=\(isUpgraded ? "true" : "false")"
        ].joined(separator: " ")
        mediaTraceLog.debug("\(line, privacy: .public)")
#else
        _ = chatId
        _ = messageId
        _ = targetWidthPx
        _ = targetHeightPx
        _ = selectedWidthPx
        _ = selectedHeightPx
        _ = isThumb
        _ = isUpgraded
#endif
    }

    static func beginSignpost(_ name: StaticString, chatId: Int64?) -> OSSignpostID {
#if DEBUG
        guard isEnabled(for: chatId) else { return .invalid }
        let signpostId = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostId)
        return signpostId
#else
        _ = name
        _ = chatId
        return .invalid
#endif
    }

    static func endSignpost(_ name: StaticString, signpostId: OSSignpostID, chatId: Int64?) {
#if DEBUG
        guard isEnabled(for: chatId) else { return }
        guard signpostId != .invalid else { return }
        os_signpost(.end, log: signpostLog, name: name, signpostID: signpostId)
#else
        _ = name
        _ = signpostId
        _ = chatId
#endif
    }
}

#if DEBUG
nonisolated final class ChatPerfTraceCollector: @unchecked Sendable {
    private struct DurationAggregate {
        var count: Int = 0
        var totalMs: Double = 0
        var maxMs: Double = 0

        mutating func record(_ durationMs: Double) {
            guard durationMs.isFinite else { return }
            guard durationMs >= 0 else { return }
            count += 1
            totalMs += durationMs
            if durationMs > maxMs {
                maxMs = durationMs
            }
        }

        var avgMs: Double {
            guard count > 0 else { return 0 }
            return totalMs / Double(count)
        }
    }

    private let log = Logger(subsystem: "com.aurora.app", category: "chat.perf")
    private let queue = DispatchQueue(label: "com.aurora.app.chat.perf.trace.queue")
    private let flushIntervalSec: Double = 2.0
    private let chatIdFilter: Int64?
    private var flushTimer: DispatchSourceTimer?

    private var windowStartNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var isLiveScrolling: Bool = false
    private var lastScrollStateChangeNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var scrollingDurationNs: UInt64 = 0
    private var snapshotReceivedCount: Int = 0
    private var snapshotReceivedScrollingCount: Int = 0
    private var snapshotReceivedIdleCount: Int = 0
    private var snapshotAppliedCount: Int = 0
    private var fullRowsRebuildCount: Int = 0
    private var fullRowsRebuildScrollingCount: Int = 0
    private var fullRowsRebuildIdleCount: Int = 0
    private var contentOnlyFastPathCount: Int = 0
    private var incrementalRowsBuildCount: Int = 0
    private var heavyEffectsDisabledCount: Int = 0
    private var buildRowsDurationMs = DurationAggregate()
    private var applyWindowMessagesDurationMs = DurationAggregate()
    private var textRenderCallCount: Int = 0
    private var textRenderCacheHitCount: Int = 0
    private var textRenderDurationMs = DurationAggregate()
    private var avatarThumbDurationMs = DurationAggregate()
    private var mediaThumbRequestCount: Int = 0
    private var mediaThumbCacheLookupCount: Int = 0
    private var mediaThumbCacheHitCount: Int = 0
    private var mediaDecodeDurationMs = DurationAggregate()
    private var snapshotInRateSamples: [Double] = []
    private var snapshotOutRateSamples: [Double] = []
    private let rateSamplesLimit = 64

    init(chatIdFilter: Int64?) {
        self.chatIdFilter = chatIdFilter
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushIntervalSec, repeating: flushIntervalSec)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        flushTimer = timer
        timer.resume()
    }

    func recordSnapshotReceived() {
        queue.async { [weak self] in
            guard let self else { return }
            self.snapshotReceivedCount += 1
            if self.isLiveScrolling {
                self.snapshotReceivedScrollingCount += 1
            } else {
                self.snapshotReceivedIdleCount += 1
            }
        }
    }

    func recordSnapshotApplied() {
        queue.async { [weak self] in
            guard let self else { return }
            self.snapshotAppliedCount += 1
        }
    }

    func recordRowsBuild(isIncremental: Bool, durationMs: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            if isIncremental {
                self.incrementalRowsBuildCount += 1
            } else {
                self.fullRowsRebuildCount += 1
                if self.isLiveScrolling {
                    self.fullRowsRebuildScrollingCount += 1
                } else {
                    self.fullRowsRebuildIdleCount += 1
                }
            }
            self.buildRowsDurationMs.record(durationMs)
        }
    }

    func recordContentOnlyFastPath() {
        queue.async { [weak self] in
            guard let self else { return }
            self.contentOnlyFastPathCount += 1
        }
    }

    func recordScrollState(_ isScrolling: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let nowNs = DispatchTime.now().uptimeNanoseconds
            self.accumulateScrollingDuration(until: nowNs)
            self.isLiveScrolling = isScrolling
        }
    }

    func recordHeavyEffectsDisabled(_ count: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard count > 0 else { return }
            self.heavyEffectsDisabledCount += count
        }
    }

    func shouldCoalesceLatest() -> Bool {
        queue.sync { snapshotCoalesceLatestEnabled }
    }

    private var snapshotCoalesceLatestEnabled: Bool = false

    func recordApplyWindowMessages(_ durationMs: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.applyWindowMessagesDurationMs.record(durationMs)
        }
    }

    func recordTextRender(_ durationMs: Double, cacheHit: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.textRenderCallCount += 1
            if cacheHit {
                self.textRenderCacheHitCount += 1
            }
            self.textRenderDurationMs.record(durationMs)
        }
    }

    func recordAvatarThumb(_ durationMs: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.avatarThumbDurationMs.record(durationMs)
        }
    }

    func recordMediaThumbRequest() {
        queue.async { [weak self] in
            guard let self else { return }
            self.mediaThumbRequestCount += 1
        }
    }

    func recordMediaThumbCacheLookup(cacheHit: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.mediaThumbCacheLookupCount += 1
            if cacheHit {
                self.mediaThumbCacheHitCount += 1
            }
        }
    }

    func recordMediaDecode(_ durationMs: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.mediaDecodeDurationMs.record(durationMs)
        }
    }

    private func flush() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        accumulateScrollingDuration(until: nowNs)
        let elapsedSec = max(0.001, Double(nowNs &- windowStartNs) / 1_000_000_000)
        let scrollingSec = min(elapsedSec, Double(scrollingDurationNs) / 1_000_000_000)
        let idleSec = max(0.001, elapsedSec - scrollingSec)

        let hasActivity =
            snapshotReceivedCount > 0 ||
            snapshotAppliedCount > 0 ||
            fullRowsRebuildCount > 0 ||
            contentOnlyFastPathCount > 0 ||
            incrementalRowsBuildCount > 0 ||
            heavyEffectsDisabledCount > 0 ||
            buildRowsDurationMs.count > 0 ||
            applyWindowMessagesDurationMs.count > 0 ||
            textRenderDurationMs.count > 0 ||
            avatarThumbDurationMs.count > 0 ||
            mediaThumbRequestCount > 0 ||
            mediaThumbCacheLookupCount > 0 ||
            mediaDecodeDurationMs.count > 0

        guard hasActivity else {
            resetWindow(nowNs: nowNs)
            return
        }

        let chatLabel = chatIdFilter.map(String.init) ?? "all"
        let snapshotsInPerSec = Double(snapshotReceivedCount) / elapsedSec
        let snapshotsOutPerSec = Double(snapshotAppliedCount) / elapsedSec
        appendRateSample(&snapshotInRateSamples, value: snapshotsInPerSec)
        appendRateSample(&snapshotOutRateSamples, value: snapshotsOutPerSec)
        let medianSnapshotsInPerSec = median(snapshotInRateSamples) ?? 0
        let medianSnapshotsOutPerSec = median(snapshotOutRateSamples) ?? 0
        let fullRebuildsPerSec = Double(fullRowsRebuildCount) / elapsedSec
        let contentOnlyFastPathPerSec = Double(contentOnlyFastPathCount) / elapsedSec
        let snapshotsPerSecScrolling = Double(snapshotReceivedScrollingCount) / max(0.001, scrollingSec)
        let snapshotsPerSecIdle = Double(snapshotReceivedIdleCount) / max(0.001, idleSec)
        let fullRebuildsPerSecScrolling = Double(fullRowsRebuildScrollingCount) / max(0.001, scrollingSec)
        let fullRebuildsPerSecIdle = Double(fullRowsRebuildIdleCount) / max(0.001, idleSec)
        let incrementalBuildsPerSec = Double(incrementalRowsBuildCount) / elapsedSec
        let heavyEffectsDisabledPerSec = Double(heavyEffectsDisabledCount) / elapsedSec
        let textRenderCallsPerSec = Double(textRenderCallCount) / elapsedSec
        let textRenderCacheHitRate = textRenderCallCount > 0
            ? Double(textRenderCacheHitCount) / Double(textRenderCallCount)
            : 0
        let mediaThumbRequestsPerSec = Double(mediaThumbRequestCount) / elapsedSec
        let mediaCacheHitRate = mediaThumbCacheLookupCount > 0
            ? Double(mediaThumbCacheHitCount) / Double(mediaThumbCacheLookupCount)
            : 0

        if scrollingSec > 0 {
            let scrollLine = [
                "CHAT_SCROLL_AGG",
                "chatId=\(chatLabel)",
                "windowSec=\(format(elapsedSec))",
                "scrollSec=\(format(scrollingSec))",
                "snapshots/s=\(format(snapshotsPerSecScrolling))",
                "fullRowsRebuilds/s=\(format(fullRebuildsPerSecScrolling))"
            ].joined(separator: " ")
            log.debug("\(scrollLine, privacy: .public)")
        }

        if !snapshotCoalesceLatestEnabled,
           snapshotsPerSecScrolling > 20 || snapshotsPerSecIdle > 10 {
            snapshotCoalesceLatestEnabled = true
            let activationLine = [
                "CHAT_COALESCE_LATEST",
                "chatId=\(chatLabel)",
                "enabled=true",
                "snapshots/s(scroll)=\(format(snapshotsPerSecScrolling))",
                "snapshots/s(idle)=\(format(snapshotsPerSecIdle))",
                "fullRowsRebuilds/s(scroll)=\(format(fullRebuildsPerSecScrolling))",
                "fullRowsRebuilds/s(idle)=\(format(fullRebuildsPerSecIdle))"
            ].joined(separator: " ")
            log.notice("\(activationLine, privacy: .public)")
        }

        let line = [
            "CHAT_PERF",
            "chatId=\(chatLabel)",
            "windowSec=\(format(elapsedSec))",
            "snapshots/s=\(format(snapshotsInPerSec))",
            "snapshotsApplied/s=\(format(snapshotsOutPerSec))",
            "medianSnapshots/s(before/after)=\(format(medianSnapshotsInPerSec))/\(format(medianSnapshotsOutPerSec))",
            "fullRebuilds/s=\(format(fullRebuildsPerSec))",
            "contentOnlyFastPath/s=\(format(contentOnlyFastPathPerSec))",
            "incrementalBuilds/s=\(format(incrementalBuildsPerSec))",
            "heavyEffectsDisabled(count/s)=\(heavyEffectsDisabledCount)/\(format(heavyEffectsDisabledPerSec))",
            "buildRowsMs(avg/max)=\(format(buildRowsDurationMs.avgMs))/\(format(buildRowsDurationMs.maxMs))",
            "applyWindowMessagesMs(avg/max)=\(format(applyWindowMessagesDurationMs.avgMs))/\(format(applyWindowMessagesDurationMs.maxMs))",
            "textRenderCalls/s=\(format(textRenderCallsPerSec))",
            "textRenderCacheHitRate=\(format(textRenderCacheHitRate * 100))%",
            "textRenderMaxMs=\(format(textRenderDurationMs.maxMs))",
            "textRenderMs(avg/max)=\(format(textRenderDurationMs.avgMs))/\(format(textRenderDurationMs.maxMs))",
            "avatarThumbMs(avg/max)=\(format(avatarThumbDurationMs.avgMs))/\(format(avatarThumbDurationMs.maxMs))",
            "mediaThumbRequests/s=\(format(mediaThumbRequestsPerSec))",
            "mediaCacheHitRate=\(format(mediaCacheHitRate * 100))%",
            "mediaDecodeMaxMs=\(format(mediaDecodeDurationMs.maxMs))"
        ].joined(separator: " ")
        log.debug("\(line, privacy: .public)")

        resetWindow(nowNs: nowNs)
    }

    private func resetWindow(nowNs: UInt64) {
        windowStartNs = nowNs
        lastScrollStateChangeNs = nowNs
        scrollingDurationNs = 0
        snapshotReceivedCount = 0
        snapshotReceivedScrollingCount = 0
        snapshotReceivedIdleCount = 0
        snapshotAppliedCount = 0
        fullRowsRebuildCount = 0
        fullRowsRebuildScrollingCount = 0
        fullRowsRebuildIdleCount = 0
        contentOnlyFastPathCount = 0
        incrementalRowsBuildCount = 0
        heavyEffectsDisabledCount = 0
        buildRowsDurationMs = DurationAggregate()
        applyWindowMessagesDurationMs = DurationAggregate()
        textRenderCallCount = 0
        textRenderCacheHitCount = 0
        textRenderDurationMs = DurationAggregate()
        avatarThumbDurationMs = DurationAggregate()
        mediaThumbRequestCount = 0
        mediaThumbCacheLookupCount = 0
        mediaThumbCacheHitCount = 0
        mediaDecodeDurationMs = DurationAggregate()
    }

    private func accumulateScrollingDuration(until nowNs: UInt64) {
        guard nowNs >= lastScrollStateChangeNs else {
            lastScrollStateChangeNs = nowNs
            return
        }
        if isLiveScrolling {
            scrollingDurationNs += nowNs - lastScrollStateChangeNs
        }
        lastScrollStateChangeNs = nowNs
    }

    private func appendRateSample(_ samples: inout [Double], value: Double) {
        guard value.isFinite else { return }
        samples.append(max(0, value))
        if samples.count > rateSamplesLimit {
            samples.removeFirst(samples.count - rateSamplesLimit)
        }
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
#endif

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
