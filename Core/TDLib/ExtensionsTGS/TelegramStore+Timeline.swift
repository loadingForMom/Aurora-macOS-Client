//  TelegramStore+Timeline.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    private func chatLastMessageOperations(
        chatId: Int64,
        messageId: Int64,
        preview: String,
        date: Int
    ) -> [DatabaseOperation] {
        [
            .updateChatLastMessage(chatId: chatId, messageId: messageId, preview: preview, date: date),
            .upsertChatLastMessage(chatId: chatId, messageId: messageId, preview: preview, date: date)
        ]
    }

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
            chatLastMessageOperations(
                chatId: chatId,
                messageId: last.id,
                preview: preview,
                date: last.date
            )
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
            chatLastMessageOperations(
                chatId: chatId,
                messageId: last.id,
                preview: preview,
                date: last.date
            )
        )
    }
}
