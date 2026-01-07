//
//  TelegramStore+Debug.swift
//  Aurora
//

import Foundation
import os

#if DEBUG
/// Stress mode (DEBUG only):
/// - Set AURORA_STRESS_MESSAGES=5000 (or 20000) to generate a synthetic chat history.
/// - Optional AURORA_STRESS_LONG_EVERY=7 to control long-message frequency.
extension TelegramStore {
    func applyStressModeIfNeeded(chatId: Int64, log: Logger) {
        guard let countString = ProcessInfo.processInfo.environment["AURORA_STRESS_MESSAGES"] else { return }
        guard let count = Int(countString), count > 0 else { return }
        if let existing = messagesByChatId[chatId], !existing.isEmpty {
            return
        }

        let longEvery = Int(ProcessInfo.processInfo.environment["AURORA_STRESS_LONG_EVERY"] ?? "7") ?? 7
        let start = Date()

        let generated = StressMessageFactory.makeMessages(chatId: chatId, count: count, longEvery: longEvery)
        messagesByChatId[chatId] = generated
        updateChatLastFromLocalTimeline(chatId: chatId)

        let elapsed = Date().timeIntervalSince(start)
        log.info("Stress mode generated \(count) messages in \(elapsed, format: .fixed(precision: 3))s")
    }
}

private enum StressMessageFactory {
    static func makeMessages(chatId: Int64, count: Int, longEvery: Int) -> [TGMessage] {
        let baseTime = Int(Date().timeIntervalSince1970) - (count * 60)
        var messages: [TGMessage] = []
        messages.reserveCapacity(count)

        for i in 0..<count {
            let isOutgoing = (i % 3 == 0)
            let isLong = longEvery > 0 && (i % longEvery == 0)
            let text = isLong ? longText(index: i) : "Test message \(i)"

            let message = TGMessage(
                id: Int64(10_000 + i),
                chatId: chatId,
                date: baseTime + (i * 60),
                isOutgoing: isOutgoing,
                senderUserId: isOutgoing ? nil : 1,
                text: text,
                sendState: .sent,
                localId: nil,
                sendingId: nil,
                editedAt: nil,
                canRetry: false
            )
            messages.append(message)
        }
        return messages
    }

    private static func longText(index: Int) -> String {
        "Long message \(index). " + Array(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit.", count: 4).joined(separator: " ")
    }
}
#endif
