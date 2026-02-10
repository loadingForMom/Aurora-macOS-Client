//  TelegramStore+History.swift
//  Aurora
//

import Foundation
import Dispatch
import os

extension TelegramStore {
    struct HistoryExtraContext {
        let chatId: Int64
        let reason: String
        let requestId: String
    }

    private var initialHistoryWindowLimit: Int { 160 }
    private var initialHistoryPageSize: Int { 50 }
    private var maxHistoryWindowLimit: Int { 5_000 }
    private var maxTdlibHistoryLimit: Int { 100 }
    private var historyAnchorJumpDiffThreshold: Int64 { 1_000_000_000 }
    private var historySkipTraceRateLimitMs: UInt64 { 500 }
    private var historyFloodWaitDefaultSeconds: Int { 1 }

    func requestInitialRemoteHistoryIfNeeded(
        chatId: Int64,
        generation: Int,
        requestedLimit: Int,
        windowLimit: Int
    ) {
        if initialRemoteRequestedGenerationByChatId[chatId] == generation {
            return
        }
        initialRemoteRequestedGenerationByChatId[chatId] = generation

        let extra = "history:\(chatId):initial:remote:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .initialRemote,
            anchorMessageId: 0,
            requestedLimit: requestedLimit,
            windowLimit: windowLimit,
            onlyLocal: false,
            generation: generation,
            anchorSource: .other,
            uiTopMessageId: nil,
            uiTopKind: nil,
            storeMinIdVisible: nil
        )
        markHistoryPaginationRequestQueued(chatId: chatId)
        syncHistoryLoadingFlagForSelectedChat()
        sendChatHistory(
            chatId: chatId,
            fromMessageId: 0,
            offset: 0,
            limit: requestedLimit,
            onlyLocal: false,
            extra: extra
        )
    }

    func loadInitialHistory(chatId: Int64) {
        reachedHistoryStart.remove(chatId)
        resetHistoryNoProgress(chatId: chatId)
        resetHistoryPaginationContext(chatId: chatId)
        setMessageWindow(chatId: chatId, windowSize: initialHistoryWindowLimit)

        // Bump generation so stale history responses can't overwrite a newer timeline.
        let generation = (historyGenerationByChatId[chatId] ?? 0) + 1
        historyGenerationByChatId[chatId] = generation

        historyWindowLimitByChatId[chatId] = initialHistoryWindowLimit
        cancelHistoryJobs(for: chatId)

        let extra = "history:\(chatId):initial:remote:\(UUID().uuidString)"
        let windowLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        let tdLimit = min(maxTdlibHistoryLimit, max(1, min(initialHistoryPageSize, windowLimit)))
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .initialRemote,
            anchorMessageId: 0,
            requestedLimit: tdLimit,
            windowLimit: windowLimit,
            onlyLocal: false,
            generation: generation,
            anchorSource: .other,
            uiTopMessageId: nil,
            uiTopKind: nil,
            storeMinIdVisible: nil
        )
        markHistoryPaginationRequestQueued(chatId: chatId)
        syncHistoryLoadingFlagForSelectedChat()
        sendChatHistory(
            chatId: chatId,
            fromMessageId: 0,
            offset: 0,
            limit: tdLimit,
            onlyLocal: false,
            extra: extra
        )
    }

    @discardableResult
    func _loadMoreHistory_impl(
        chatId: Int64,
        anchorMessageId: Int64,
        pageSize: Int,
        uiTopMessageId: Int64? = nil,
        uiTopKind: String? = nil,
        storeMinIdVisible: Int64? = nil,
        anchorSource: PaginationAnchorSource = .other
    ) -> Bool {
        let hasReachedStart = reachedHistoryStart.contains(chatId)
        let hasOlderInFlight = historyJobs.values.contains(where: { $0.chatId == chatId && $0.kind == .older })
        let normalizedPageSize = max(1, pageSize)
        let currentLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        let reachedWindowCap = currentLimit >= maxHistoryWindowLimit
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let pausedUntilNs = historyCooldownUntilNs(chatId: chatId, nowNs: nowNs)
        let effectiveAnchorMessageId = resolvedHistoryAnchor(
            chatId: chatId,
            requestedAnchorMessageId: anchorMessageId
        )

        if hasReachedStart {
            traceHistorySkip(
                chatId: chatId,
                reason: "older",
                skipReason: "endReached",
                anchorMessageId: effectiveAnchorMessageId,
                flags: [
                    ("hasReachedStart", HistoryTrace.boolValue(hasReachedStart)),
                    ("hasOlderInFlight", HistoryTrace.boolValue(hasOlderInFlight)),
                    ("currentLimit", String(currentLimit)),
                    ("maxLimit", String(maxHistoryWindowLimit))
                ]
            )
            syncHistoryPaginationCanLoadMore(chatId: chatId)
            return false
        }

        if effectiveAnchorMessageId <= 0 {
            traceHistorySkip(
                chatId: chatId,
                reason: "older",
                skipReason: "noAnchor",
                anchorMessageId: effectiveAnchorMessageId,
                flags: [
                    ("hasReachedStart", HistoryTrace.boolValue(hasReachedStart)),
                    ("hasOlderInFlight", HistoryTrace.boolValue(hasOlderInFlight)),
                    ("currentLimit", String(currentLimit)),
                    ("maxLimit", String(maxHistoryWindowLimit))
                ]
            )
            return false
        }

        if hasOlderInFlight {
            traceHistorySkip(
                chatId: chatId,
                reason: "older",
                skipReason: "inFlight",
                anchorMessageId: effectiveAnchorMessageId,
                flags: [
                    ("hasReachedStart", HistoryTrace.boolValue(hasReachedStart)),
                    ("hasOlderInFlight", HistoryTrace.boolValue(hasOlderInFlight)),
                    ("currentLimit", String(currentLimit)),
                    ("maxLimit", String(maxHistoryWindowLimit))
                ]
            )
            return false
        }

        if reachedWindowCap {
            traceHistorySkip(
                chatId: chatId,
                reason: "older",
                skipReason: "other",
                anchorMessageId: effectiveAnchorMessageId,
                flags: [
                    ("cause", "maxWindowLimit"),
                    ("hasReachedStart", HistoryTrace.boolValue(hasReachedStart)),
                    ("hasOlderInFlight", HistoryTrace.boolValue(hasOlderInFlight)),
                    ("currentLimit", String(currentLimit)),
                    ("maxLimit", String(maxHistoryWindowLimit))
                ]
            )
            return false
        }

        if pausedUntilNs > nowNs {
            traceHistorySkip(
                chatId: chatId,
                reason: "older",
                skipReason: "cooldown",
                anchorMessageId: effectiveAnchorMessageId,
                flags: [
                    ("pausedUntil", historyPausedUntilString(untilNs: pausedUntilNs, nowNs: nowNs)),
                    ("cooldownSecondsRemaining", String(historyRemainingCooldownSeconds(untilNs: pausedUntilNs, nowNs: nowNs)))
                ]
            )
            return false
        }

        let target = min(maxHistoryWindowLimit, currentLimit + normalizedPageSize)
        historyWindowLimitByChatId[chatId] = target
        setMessageWindow(chatId: chatId, windowSize: target)
        let tdLimit = min(maxTdlibHistoryLimit, normalizedPageSize)

        let extra = "history:\(chatId):older:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .older,
            anchorMessageId: effectiveAnchorMessageId,
            requestedLimit: tdLimit,
            windowLimit: target,
            onlyLocal: false,
            generation: historyGenerationByChatId[chatId] ?? 0,
            anchorSource: anchorSource,
            uiTopMessageId: uiTopMessageId,
            uiTopKind: uiTopKind,
            storeMinIdVisible: storeMinIdVisible
        )
        markHistoryPaginationRequestQueued(chatId: chatId)
        syncHistoryLoadingFlagForSelectedChat()

        // TDLib getChatHistory(chat_id, from_message_id, offset, limit, only_local).
        // offset=0 may include the anchor message; we dedupe by message_id later.
        sendChatHistory(
            chatId: chatId,
            fromMessageId: effectiveAnchorMessageId,
            offset: 0,
            limit: tdLimit,
            onlyLocal: false,
            extra: extra
        )
        return true
    }

    @discardableResult
    func loadHistoryAroundMessage(
        chatId: Int64,
        messageId: Int64,
        pageSize: Int = 80
    ) -> Bool {
        guard messageId > 0 else { return false }

        let normalizedPageSize = max(20, min(pageSize, maxTdlibHistoryLimit))
        let hasAroundInFlight = historyJobs.values.contains(where: {
            $0.chatId == chatId && $0.kind == .around && $0.anchorMessageId == messageId
        })
        if hasAroundInFlight {
            traceHistorySkip(
                chatId: chatId,
                reason: "around",
                skipReason: "inFlight",
                anchorMessageId: messageId
            )
            return false
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let pausedUntilNs = historyCooldownUntilNs(chatId: chatId, nowNs: nowNs)
        if pausedUntilNs > nowNs {
            traceHistorySkip(
                chatId: chatId,
                reason: "around",
                skipReason: "cooldown",
                anchorMessageId: messageId,
                flags: [
                    ("pausedUntil", historyPausedUntilString(untilNs: pausedUntilNs, nowNs: nowNs)),
                    ("cooldownSecondsRemaining", String(historyRemainingCooldownSeconds(untilNs: pausedUntilNs, nowNs: nowNs)))
                ]
            )
            return false
        }

        let currentLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        let targetWindowLimit = min(
            maxHistoryWindowLimit,
            max(currentLimit, max(initialHistoryWindowLimit, normalizedPageSize * 2))
        )
        historyWindowLimitByChatId[chatId] = targetWindowLimit
        setMessageWindow(chatId: chatId, windowSize: targetWindowLimit)

        let extra = "history:\(chatId):around:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .around,
            anchorMessageId: messageId,
            requestedLimit: normalizedPageSize,
            windowLimit: targetWindowLimit,
            onlyLocal: false,
            generation: historyGenerationByChatId[chatId] ?? 0,
            anchorSource: .other,
            uiTopMessageId: nil,
            uiTopKind: nil,
            storeMinIdVisible: nil
        )
        syncHistoryLoadingFlagForSelectedChat()

        // Use a negative offset so TDLib returns a slice around the target id.
        let aroundOffset = -max(1, normalizedPageSize / 2)
        sendChatHistory(
            chatId: chatId,
            fromMessageId: messageId,
            offset: aroundOffset,
            limit: normalizedPageSize,
            onlyLocal: false,
            extra: extra
        )
        return true
    }

    func cancelHistoryJobs(for chatId: Int64) {
        let keys = historyJobs.compactMap { (k, v) in v.chatId == chatId ? k : nil }
        for k in keys {
            historyJobs.removeValue(forKey: k)
            historyRequestStartedAtNs.removeValue(forKey: k)
        }
        initialRemoteRequestedGenerationByChatId.removeValue(forKey: chatId)
        resetHistoryNoProgress(chatId: chatId)
        var paginationState = historyPaginationState(chatId: chatId)
        paginationState.isLoadingMore = false
        historyPaginationStateByChatId[chatId] = paginationState
        syncHistoryLoadingFlagForSelectedChat()
    }

    func syncHistoryLoadingFlagForSelectedChat() {
        let selected = selectedChatId
        let loading = selected.map { chatId in
            historyJobs.values.contains(where: { $0.chatId == chatId })
        } ?? false

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard self.selectedChatId == selected else { return }
            if self.isLoadingHistory != loading {
                self.isLoadingHistory = loading
                AuroraRuntimeMetrics.shared.incrementPublish("storeHistoryLoading")
            }
        }
    }

    func sendChatHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int, onlyLocal: Bool, extra: String) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let pausedUntilNs = historyCooldownUntilNs(chatId: chatId, nowNs: nowNs)
        if pausedUntilNs > nowNs {
            let job = historyJobs[extra]
            traceHistorySkip(
                chatId: chatId,
                reason: historyReason(for: job?.kind),
                skipReason: "cooldown",
                anchorMessageId: fromMessageId,
                flags: [
                    ("requestId", historyRequestId(from: extra)),
                    ("extra", extra),
                    ("pausedUntil", historyPausedUntilString(untilNs: pausedUntilNs, nowNs: nowNs)),
                    ("cooldownSecondsRemaining", String(historyRemainingCooldownSeconds(untilNs: pausedUntilNs, nowNs: nowNs)))
                ]
            )
            applyHistoryPaginationError(extra: extra, message: "History cooldown is active")
            discardHistoryJob(extra: extra)
            syncHistoryLoadingFlagForSelectedChat()
            return
        }

        historyRequestStartedAtNs[extra] = nowNs
        if onlyLocal {
            historyMetrics.requestsLocal += 1
        } else {
            historyMetrics.requestsRemote += 1
        }
        historyMetrics.maxInFlightJobs = max(historyMetrics.maxInFlightJobs, historyJobs.count)

#if DEBUG
        let inFlightCount = historyJobs.count
        log.debug("history request queued chatId=\(chatId, privacy: .public) from=\(fromMessageId, privacy: .public) offset=\(offset, privacy: .public) limit=\(limit, privacy: .public) local=\(onlyLocal, privacy: .public) inFlight=\(inFlightCount, privacy: .public)")
#endif

        let traceEnabled = HistoryTrace.isEnabled(for: chatId)
        if traceEnabled {
            let job = historyJobs[extra]
            let bounds = databaseRepository.fetchMessageBounds(chatId: chatId)
            let reason = historyReason(for: job?.kind)
            let inFlightCountForChat = historyInFlightCount(chatId: chatId)
            let uiTopMessageId = job?.uiTopMessageId
            let uiTopKind = job?.uiTopKind ?? "null"
            let storeMinIdVisible = job?.storeMinIdVisible
            let anchorSource = job?.anchorSource.rawValue ?? PaginationAnchorSource.other.rawValue
            let uiTopDiff: Int64? = {
                guard let uiTopMessageId, bounds.minId != 0 else { return nil }
                return uiTopMessageId - bounds.minId
            }()

            HistoryTrace.emit(
                tag: "HIST_REQ",
                chatId: chatId,
                fields: [
                    ("reason", reason),
                    ("requestId", historyRequestId(from: extra)),
                    ("extra", extra),
                    ("from_message_id", String(fromMessageId)),
                    ("offset", String(offset)),
                    ("limit", String(limit)),
                    ("only_local", HistoryTrace.boolValue(onlyLocal)),
                    ("inFlightCount", String(inFlightCountForChat)),
                    ("storeMinId", String(bounds.minId)),
                    ("storeMaxId", String(bounds.maxId)),
                    ("storeCount", String(bounds.count)),
                    ("storeMinIdRaw", String(bounds.minId)),
                    ("storeMinIdVisible", HistoryTrace.optionalInt64(storeMinIdVisible)),
                    ("uiTopMessageId", HistoryTrace.optionalInt64(uiTopMessageId)),
                    ("uiTopKind", uiTopKind),
                    ("uiTopVsStoreMinDiff", HistoryTrace.optionalInt64(uiTopDiff)),
                    ("paginationAnchorSource", anchorSource)
                ]
            )

            if reason == "older", bounds.minId > 0 {
                let diff = bounds.minId - fromMessageId
                let jumpByRatio = fromMessageId < Int64(Double(bounds.minId) * 0.98)
                let jumpByDiff = diff > historyAnchorJumpDiffThreshold
                if diff > 0, (jumpByRatio || jumpByDiff) {
                    HistoryTrace.emit(
                        tag: "HIST_WARN",
                        chatId: chatId,
                        fields: [
                            ("type", "ANCHOR_JUMP_TOO_OLD"),
                            ("reason", reason),
                            ("requestId", historyRequestId(from: extra)),
                            ("storeMinId", String(bounds.minId)),
                            ("from_message_id", String(fromMessageId)),
                            ("diff", String(diff)),
                            ("paginationAnchorSource", anchorSource)
                        ]
                    )
                }
            }
        }

        let req: [String: Any] = [
            "@type": "getChatHistory",
            "@extra": extra,
            "chat_id": chatId,
            "from_message_id": fromMessageId,
            "offset": offset,
            "limit": limit,
            "only_local": onlyLocal
        ]
        enqueueTDLibRequest(req, typeOverride: "getChatHistory", priority: .high)
    }

    func historyReason(for kind: HistoryJobKind?) -> String {
        guard let kind else { return "other" }
        switch kind {
        case .initialLocal:
            return "initial_local"
        case .initialRemote:
            return "initial_remote"
        case .older:
            return "older"
        case .around:
            return "around"
        }
    }

    func historyRequestId(from extra: String) -> String {
        extra.split(separator: ":").last.map(String.init) ?? extra
    }

    func parseHistoryExtraContext(_ extra: String) -> HistoryExtraContext? {
        let parts = extra.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        guard parts[0] == "history" else { return nil }
        guard let chatId = Int64(parts[1]) else { return nil }

        let reason: String
        if parts.count >= 5, parts[2] == "initial", parts[3] == "local" {
            reason = "initial_local"
        } else if parts.count >= 5, parts[2] == "initial", parts[3] == "remote" {
            reason = "initial_remote"
        } else if parts[2] == "older" {
            reason = "older"
        } else if parts[2] == "around" {
            reason = "around"
        } else {
            reason = "other"
        }

        return HistoryExtraContext(
            chatId: chatId,
            reason: reason,
            requestId: historyRequestId(from: extra)
        )
    }

    func traceHistorySkip(
        chatId: Int64,
        reason: String,
        skipReason: String,
        anchorMessageId: Int64,
        flags: [(String, String)] = []
    ) {
        guard HistoryTrace.isEnabled(for: chatId) else { return }
        var fields: [(String, String)] = [
            ("reason", reason),
            ("skipReason", skipReason),
            ("anchorMessageId", String(anchorMessageId)),
            ("inFlightCount", String(historyInFlightCount(chatId: chatId))),
            ("selectedChatId", HistoryTrace.optionalInt64(selectedChatId)),
            ("isLoadingHistory", HistoryTrace.boolValue(isLoadingHistory)),
            ("reachedHistoryStart", HistoryTrace.boolValue(reachedHistoryStart.contains(chatId)))
        ]
        fields.append(contentsOf: flags)
        HistoryTrace.emit(
            tag: "HIST_SKIP",
            chatId: chatId,
            fields: fields,
            rateKey: "store:\(chatId):\(reason):\(skipReason)",
            rateLimitMs: historySkipTraceRateLimitMs
        )
    }

    func historyInFlightCount(chatId: Int64) -> Int {
        historyJobs.values.reduce(into: 0) { result, job in
            if job.chatId == chatId {
                result += 1
            }
        }
    }

    func resetHistoryNoProgress(chatId: Int64) {
        historyNoProgressByChatId.removeValue(forKey: chatId)
    }

    @discardableResult
    func registerHistoryNoProgress(chatId: Int64, anchorMessageId: Int64) -> Int {
        let current = historyNoProgressByChatId[chatId]
        let attempts: Int
        if let current, current.anchorMessageId == anchorMessageId {
            attempts = current.attempts + 1
        } else {
            attempts = 1
        }
        historyNoProgressByChatId[chatId] = (anchorMessageId: anchorMessageId, attempts: attempts)
        return attempts
    }

    func discardHistoryJob(extra: String) {
        if let job = historyJobs.removeValue(forKey: extra) {
            if job.kind == .initialRemote,
               initialRemoteRequestedGenerationByChatId[job.chatId] == job.generation {
                initialRemoteRequestedGenerationByChatId.removeValue(forKey: job.chatId)
            }
            if !historyJobs.values.contains(where: { $0.chatId == job.chatId }) {
                var state = historyPaginationState(chatId: job.chatId)
                state.isLoadingMore = false
                state.canLoadMore = !reachedHistoryStart.contains(job.chatId)
                if !state.canLoadMore {
                    state.nextOffset = nil
                }
                historyPaginationStateByChatId[job.chatId] = state
            }
        }
        historyRequestStartedAtNs.removeValue(forKey: extra)
    }

    func historyCooldownUntilNs(chatId: Int64, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        if historyGlobalPausedUntilNs <= nowNs {
            historyGlobalPausedUntilNs = 0
        }
        if let perChat = historyPausedUntilNsByChatId[chatId], perChat <= nowNs {
            historyPausedUntilNsByChatId.removeValue(forKey: chatId)
        }
        return max(historyGlobalPausedUntilNs, historyPausedUntilNsByChatId[chatId] ?? 0)
    }

    @discardableResult
    func applyHistoryFloodWaitCooldown(chatId: Int64?, seconds: Int) -> UInt64 {
        let clampedSeconds = max(historyFloodWaitDefaultSeconds, seconds)
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let deltaNs = UInt64(clampedSeconds) * 1_000_000_000
        let pausedUntilNs = nowNs > (UInt64.max - deltaNs) ? UInt64.max : (nowNs + deltaNs)
        historyGlobalPausedUntilNs = max(historyGlobalPausedUntilNs, pausedUntilNs)
        if let chatId {
            historyPausedUntilNsByChatId[chatId] = max(historyPausedUntilNsByChatId[chatId] ?? 0, pausedUntilNs)
        }
        return pausedUntilNs
    }

    func historyRemainingCooldownSeconds(untilNs: UInt64, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int {
        guard untilNs > nowNs else { return 0 }
        let remainingNs = untilNs - nowNs
        let roundedUp = (remainingNs + 999_999_999) / 1_000_000_000
        return Int(min(roundedUp, UInt64(Int.max)))
    }

    func historyPausedUntilString(untilNs: UInt64, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> String {
        guard untilNs > nowNs else { return "null" }
        let remainingNs = untilNs - nowNs
        let pausedUntilDate = Date().addingTimeInterval(Double(remainingNs) / 1_000_000_000.0)
        return ISO8601DateFormatter().string(from: pausedUntilDate)
    }

    func parseFloodWaitSeconds(message: String, extra: String?) -> Int? {
        if let fromMessage = extractFloodWaitSeconds(from: message) {
            return fromMessage
        }
        if let extra, let fromExtra = extractFloodWaitSeconds(from: extra) {
            return fromExtra
        }
        return nil
    }

    private func extractFloodWaitSeconds(from value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()

        if let floodRange = upper.range(of: "FLOOD_WAIT_") {
            let suffix = upper[floodRange.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let parsed = Int(digits), parsed > 0 {
                return parsed
            }
        }

        if upper.contains("FLOOD_WAIT") {
            let digits = upper.split { !$0.isNumber }.compactMap { Int($0) }
            if let parsed = digits.first(where: { $0 > 0 }) {
                return parsed
            }
        }

        let patterns = [
            #"(?i)retry\s+after\s+([0-9]+)"#,
            #"(?i)wait\s+([0-9]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
                  match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: trimmed),
                  let parsed = Int(trimmed[range]),
                  parsed > 0
            else { continue }
            return parsed
        }
        return nil
    }

}
