//
//  VisibilityBatcher.swift
//  Aurora
//

import Foundation

@MainActor
final class VisibilityBatcher {
    struct DrainResult {
        let latestVisibilityByMessageId: [Int64: Bool]
        let bufferedEvents: Int
    }

    private var latestVisibilityByMessageId: [Int64: Bool] = [:]
    private var bufferedEvents: Int = 0

    var hasPendingChanges: Bool {
        !latestVisibilityByMessageId.isEmpty
    }

    var pendingMessageCount: Int {
        latestVisibilityByMessageId.count
    }

    @discardableResult
    func record(messageId: Int64, isVisible: Bool) -> Bool {
        bufferedEvents += 1
        let previous = latestVisibilityByMessageId.updateValue(isVisible, forKey: messageId)
        return previous != isVisible
    }

    func drain() -> DrainResult {
        let snapshot = latestVisibilityByMessageId
        let eventsCount = bufferedEvents
        latestVisibilityByMessageId.removeAll(keepingCapacity: true)
        bufferedEvents = 0
        return DrainResult(
            latestVisibilityByMessageId: snapshot,
            bufferedEvents: eventsCount
        )
    }

    func clear() {
        latestVisibilityByMessageId.removeAll(keepingCapacity: true)
        bufferedEvents = 0
    }
}
