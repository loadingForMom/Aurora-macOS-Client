//  TelegramStore+Timeline.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func keepOptimisticChatPreviewIfNeeded(chatId: Int64) async {
        guard let last = databaseRepository.fetchLatestMessage(chatId: chatId) else { return }
        guard last.isOutgoing else { return }
        if case .sent = last.sendState { return }

        let preview: String
        switch last.sendState {
        case .pending, .sending:
            preview = "You: (sending…) \(last.previewText)"
        case .failed:
            preview = "You: (failed) \(last.previewText)"
        case .sent:
            preview = last.previewText
        }

        await databaseBatchWriter.enqueue(
            .updateChatLastMessage(chatId: chatId, messageId: last.id, preview: preview, date: last.date)
        )
        await databaseBatchWriter.enqueue(
            .upsertChatLastMessage(chatId: chatId, messageId: last.id, preview: preview, date: last.date)
        )
    }

    func updateChatLastFromLocalTimeline(chatId: Int64) async {
        guard let last = databaseRepository.fetchLatestMessage(chatId: chatId) else { return }
        let preview: String
        switch last.sendState {
        case .pending, .sending:
            preview = "You: (sending…) \(last.previewText)"
        case .failed:
            preview = "You: (failed) \(last.previewText)"
        case .sent:
            preview = last.previewText
        }

        await databaseBatchWriter.enqueue(
            .updateChatLastMessage(chatId: chatId, messageId: last.id, preview: preview, date: last.date)
        )
        await databaseBatchWriter.enqueue(
            .upsertChatLastMessage(chatId: chatId, messageId: last.id, preview: preview, date: last.date)
        )
    }
}
