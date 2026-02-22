//
//  ScrollStateCoordinator.swift
//  Aurora
//

import Foundation
import CoreGraphics

@MainActor
final class ScrollStateCoordinator {
    enum TopLoadTriggerState: String {
        case idle
        case armed
        case triggered
    }

    enum TopSentinelIgnoreReason: String {
        case invalidValue
        case withinEpsilon
    }

    struct TopSentinelUpdate {
        let ignoreReason: TopSentinelIgnoreReason?
        let isNearTop: Bool
        let triggerState: TopLoadTriggerState
        let nearTopChanged: Bool
        let triggerStateChanged: Bool
        let shouldTriggerLoad: Bool

        var isIgnored: Bool {
            ignoreReason != nil
        }
    }

    struct GroupRowOffsetsUpdate {
        let didChange: Bool
        let count: Int
    }

    private let topThreshold: CGFloat
    private let topHysteresis: CGFloat
    private let topSampleEpsilon: CGFloat
    private let groupRowEpsilon: CGFloat

    private var lastTopSentinelSample: CGFloat = .nan
    private(set) var isNearTop: Bool = false
    private(set) var topLoadTriggerState: TopLoadTriggerState = .idle
    private var groupRowMinYById: [String: CGFloat] = [:]

    init(
        topThreshold: CGFloat = 260,
        topHysteresis: CGFloat = 14,
        topSampleEpsilon: CGFloat = 1,
        groupRowEpsilon: CGFloat = 0.75
    ) {
        self.topThreshold = topThreshold
        self.topHysteresis = topHysteresis
        self.topSampleEpsilon = topSampleEpsilon
        self.groupRowEpsilon = groupRowEpsilon
    }

    func reset() {
        lastTopSentinelSample = .nan
        isNearTop = false
        topLoadTriggerState = .idle
        groupRowMinYById = [:]
    }

    func ingestTopSentinelOffset(_ minY: CGFloat, allowTrigger: Bool) -> TopSentinelUpdate {
        guard minY.isFinite else {
            return TopSentinelUpdate(
                ignoreReason: .invalidValue,
                isNearTop: isNearTop,
                triggerState: topLoadTriggerState,
                nearTopChanged: false,
                triggerStateChanged: false,
                shouldTriggerLoad: false
            )
        }

        if lastTopSentinelSample.isFinite,
           abs(minY - lastTopSentinelSample) < topSampleEpsilon {
            return TopSentinelUpdate(
                ignoreReason: .withinEpsilon,
                isNearTop: isNearTop,
                triggerState: topLoadTriggerState,
                nearTopChanged: false,
                triggerStateChanged: false,
                shouldTriggerLoad: false
            )
        }
        lastTopSentinelSample = minY

        let previousNearTop = isNearTop
        let previousTriggerState = topLoadTriggerState

        let nextNearTop = computeNearTop(minY)
        isNearTop = nextNearTop

        // Arm once per near-top pass; this avoids retrigger spam on every tick.
        if !nextNearTop {
            topLoadTriggerState = .idle
        } else if topLoadTriggerState == .idle {
            topLoadTriggerState = .armed
        }

        var shouldTriggerLoad = false
        if allowTrigger,
           nextNearTop,
           topLoadTriggerState == .armed {
            topLoadTriggerState = .triggered
            shouldTriggerLoad = true
        }

        return TopSentinelUpdate(
            ignoreReason: nil,
            isNearTop: isNearTop,
            triggerState: topLoadTriggerState,
            nearTopChanged: previousNearTop != isNearTop,
            triggerStateChanged: previousTriggerState != topLoadTriggerState,
            shouldTriggerLoad: shouldTriggerLoad
        )
    }

    func reconcileTopSentinelTrigger(allowTrigger: Bool) -> Bool {
        guard allowTrigger else { return false }
        guard isNearTop else { return false }
        guard topLoadTriggerState == .armed else { return false }
        topLoadTriggerState = .triggered
        return true
    }

    func updateGroupRowMinY(_ map: [String: CGFloat]) -> GroupRowOffsetsUpdate {
        guard shouldReplaceGroupRowOffsets(with: map) else {
            return GroupRowOffsetsUpdate(didChange: false, count: groupRowMinYById.count)
        }
        groupRowMinYById = map
        return GroupRowOffsetsUpdate(didChange: true, count: map.count)
    }

    func groupRowMinY(for rowId: String) -> CGFloat? {
        groupRowMinYById[rowId]
    }

    private func computeNearTop(_ minY: CGFloat) -> Bool {
        // Hysteresis keeps near-top state stable around threshold jitter.
        if isNearTop {
            return minY >= (-topThreshold - topHysteresis)
        }
        return minY >= (-topThreshold + topHysteresis)
    }

    private func shouldReplaceGroupRowOffsets(with next: [String: CGFloat]) -> Bool {
        if groupRowMinYById.count != next.count {
            return true
        }

        for (key, oldValue) in groupRowMinYById {
            guard let nextValue = next[key] else { return true }

            if oldValue.isNaN || nextValue.isNaN {
                if oldValue.isNaN != nextValue.isNaN { return true }
                continue
            }

            if !oldValue.isFinite || !nextValue.isFinite {
                if oldValue != nextValue { return true }
                continue
            }

            if abs(oldValue - nextValue) >= groupRowEpsilon {
                return true
            }
        }

        return false
    }
}
