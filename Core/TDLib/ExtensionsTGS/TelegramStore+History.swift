//  TelegramStore+History.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func loadLatestHistory(chatId: Int64) {
        isLoadingHistory = (selectedChatId == chatId)
        reachedHistoryStart.remove(chatId)

        messagesByChatId[chatId] = []
        cancelHistoryJobs(for: chatId)

        let extra = "history:\(chatId):latest:\(UUID().uuidString)"
        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            targetCount: 160,
            nextFromMessageId: 0,
            accById: [:],
            kind: .latest
        )
        sendChatHistory(chatId: chatId, fromMessageId: 0, offset: 0, limit: 100, extra: extra)
    }

    func _loadMoreHistory_impl(chatId: Int64, pageSize: Int) {
        if isLoadingHistory { return }
        if reachedHistoryStart.contains(chatId) { return }

        guard let current = messagesByChatId[chatId], !current.isEmpty else {
            loadLatestHistory(chatId: chatId)
            return
        }

        if current.count >= 800 { return }

        isLoadingHistory = (selectedChatId == chatId)

        let serverMsgs = current.filter { $0.id > 0 }
        guard let oldestServerId = serverMsgs.min(by: { $0.id < $1.id })?.id else {
            isLoadingHistory = false
            return
        }

        let target = min(800, current.count + pageSize)
        let extra = "history:\(chatId):older:\(UUID().uuidString)"

        historyJobs[extra] = HistoryJob(
            chatId: chatId,
            targetCount: target,
            nextFromMessageId: oldestServerId,
            accById: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) }),
            kind: .older
        )

        sendChatHistory(chatId: chatId, fromMessageId: oldestServerId, offset: 0, limit: pageSize, extra: extra)
    }

    func cancelHistoryJobs(for chatId: Int64) {
        let keys = historyJobs.compactMap { (k, v) in v.chatId == chatId ? k : nil }
        for k in keys { historyJobs.removeValue(forKey: k) }
    }

    func sendChatHistory(chatId: Int64, fromMessageId: Int64, offset: Int, limit: Int, extra: String) {
        let req: [String: Any] = [
            "@type": "getChatHistory",
            "@extra": extra,
            "chat_id": chatId,
            "from_message_id": fromMessageId,
            "offset": offset,
            "limit": limit,
            "only_local": false
        ]
        sendJSON(req)
    }
}
