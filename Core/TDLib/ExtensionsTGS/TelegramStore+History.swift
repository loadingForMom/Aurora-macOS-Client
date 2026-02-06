//  TelegramStore+History.swift
//  Aurora
//

import Foundation
import Dispatch
import os

extension TelegramStore {

    private var initialHistoryWindowLimit: Int { 160 }
    private var maxHistoryWindowLimit: Int { 5_000 }
    private var maxTdlibHistoryLimit: Int { 100 }

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
            generation: generation
        )
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
        setMessageWindow(chatId: chatId, windowSize: initialHistoryWindowLimit)

        // Bump generation so stale history responses can't overwrite a newer timeline.
        let generation = (historyGenerationByChatId[chatId] ?? 0) + 1
        historyGenerationByChatId[chatId] = generation

        historyWindowLimitByChatId[chatId] = initialHistoryWindowLimit
        cancelHistoryJobs(for: chatId)

        let extra = "history:\(chatId):initial:local:\(UUID().uuidString)"
        let windowLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        let tdLimit = min(maxTdlibHistoryLimit, windowLimit)
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .initialLocal,
            anchorMessageId: 0,
            requestedLimit: tdLimit,
            windowLimit: windowLimit,
            onlyLocal: true,
            generation: generation
        )
        syncHistoryLoadingFlagForSelectedChat()
        sendChatHistory(
            chatId: chatId,
            fromMessageId: 0,
            offset: 0,
            limit: tdLimit,
            onlyLocal: true,
            extra: extra
        )
    }

    func _loadMoreHistory_impl(chatId: Int64, anchorMessageId: Int64, pageSize: Int) {
        if reachedHistoryStart.contains(chatId) { return }
        if anchorMessageId <= 0 { return }
        if historyJobs.values.contains(where: { $0.chatId == chatId && $0.kind == .older }) { return }

        let currentLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        if currentLimit >= maxHistoryWindowLimit { return }

        let target = min(maxHistoryWindowLimit, currentLimit + pageSize)
        historyWindowLimitByChatId[chatId] = target
        setMessageWindow(chatId: chatId, windowSize: target)
        let tdLimit = min(maxTdlibHistoryLimit, max(1, pageSize + 1))

        let extra = "history:\(chatId):older:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .older,
            anchorMessageId: anchorMessageId,
            requestedLimit: tdLimit,
            windowLimit: target,
            onlyLocal: false,
            generation: historyGenerationByChatId[chatId] ?? 0
        )
        syncHistoryLoadingFlagForSelectedChat()

        // TDLib getChatHistory(chat_id, from_message_id, offset, limit, only_local).
        // offset=0 includes the anchor message; we request limit+1 and dedupe by message_id.
        sendChatHistory(
            chatId: chatId,
            fromMessageId: anchorMessageId,
            offset: 0,
            limit: tdLimit,
            onlyLocal: false,
            extra: extra
        )
    }

    func cancelHistoryJobs(for chatId: Int64) {
        let keys = historyJobs.compactMap { (k, v) in v.chatId == chatId ? k : nil }
        for k in keys {
            historyJobs.removeValue(forKey: k)
            historyRequestStartedAtNs.removeValue(forKey: k)
        }
        initialRemoteRequestedGenerationByChatId.removeValue(forKey: chatId)
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
        historyRequestStartedAtNs[extra] = DispatchTime.now().uptimeNanoseconds
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

}
