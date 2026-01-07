//  TelegramStore+History.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    private var initialHistoryWindowLimit: Int { 160 }
    private var maxHistoryWindowLimit: Int { 800 }

    func loadInitialHistory(chatId: Int64) {
        isLoadingHistory = (selectedChatId == chatId)
        reachedHistoryStart.remove(chatId)

        // Bump generation so stale history responses can't overwrite a newer timeline.
        let generation = (historyGenerationByChatId[chatId] ?? 0) + 1
        historyGenerationByChatId[chatId] = generation

        historyWindowLimitByChatId[chatId] = initialHistoryWindowLimit
        if let cached = databaseRepository?.fetchLatestMessages(chatId: chatId, limit: initialHistoryWindowLimit) {
            if cached.isEmpty {
                messagesByChatId[chatId] = []
            } else {
                mergeMessages(chatId: chatId, incoming: cached, windowLimit: initialHistoryWindowLimit, reason: "initial-local")
            }
        } else {
            messagesByChatId[chatId] = []
        }
        cancelHistoryJobs(for: chatId)

        let extra = "history:\(chatId):initial:local:\(UUID().uuidString)"
        let windowLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .initialLocal,
            anchorMessageId: 0,
            requestedLimit: min(100, windowLimit),
            windowLimit: windowLimit,
            onlyLocal: true,
            generation: generation
        )
        sendChatHistory(
            chatId: chatId,
            fromMessageId: 0,
            offset: 0,
            limit: min(100, windowLimit),
            onlyLocal: true,
            extra: extra
        )
    }

    func _loadMoreHistory_impl(chatId: Int64, anchorMessageId: Int64, pageSize: Int) {
        if isLoadingHistory { return }
        if reachedHistoryStart.contains(chatId) { return }
        if anchorMessageId <= 0 { return }

        let currentLimit = historyWindowLimitByChatId[chatId] ?? initialHistoryWindowLimit
        if currentLimit >= maxHistoryWindowLimit { return }

        isLoadingHistory = (selectedChatId == chatId)
        let target = min(maxHistoryWindowLimit, currentLimit + pageSize)
        historyWindowLimitByChatId[chatId] = target

        let extra = "history:\(chatId):older:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            kind: .older,
            anchorMessageId: anchorMessageId,
            requestedLimit: pageSize,
            windowLimit: target,
            onlyLocal: false,
            generation: historyGenerationByChatId[chatId] ?? 0
        )

        // TDLib getChatHistory(chat_id, from_message_id, offset, limit, only_local).
        // We use offset = -1 so the result is strictly older than the anchor message.
        sendChatHistory(
            chatId: chatId,
            fromMessageId: anchorMessageId,
            offset: -1,
            limit: pageSize,
            onlyLocal: false,
            extra: extra
        )
    }

    func cancelHistoryJobs(for chatId: Int64) {
        let keys = historyJobs.compactMap { (k, v) in v.chatId == chatId ? k : nil }
        for k in keys { historyJobs.removeValue(forKey: k) }
    }

    func sendChatHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int, onlyLocal: Bool, extra: String) {
        let req: [String: Any] = [
            "@type": "getChatHistory",
            "@extra": extra,
            "chat_id": chatId,
            "from_message_id": fromMessageId,
            "offset": offset,
            "limit": limit,
            "only_local": onlyLocal
        ]
        sendJSON(req)
    }

    func refreshMessagesWindow(chatId: Int64) {
        guard let windowLimit = historyWindowLimitByChatId[chatId] else { return }
        guard let databaseRepository else { return }
        let latest = databaseRepository.fetchLatestMessages(chatId: chatId, limit: windowLimit)
        mergeMessages(chatId: chatId, incoming: latest, windowLimit: windowLimit, reason: "db-window")
    }
}
