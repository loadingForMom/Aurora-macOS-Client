//  TelegramStore+HistoryPaginationContext.swift
//  Aurora
//

import Foundation

extension TelegramStore {
    struct HistoryPaginationContextState: Equatable {
        var items: [Int64]
        var isLoadingMore: Bool
        var canLoadMore: Bool
        var nextOffset: Int64?
        var error: String?
    }

    func historyPaginationState(chatId: Int64) -> HistoryPaginationContextState {
        historyPaginationStateByChatId[chatId] ?? HistoryPaginationContextState(
            items: [],
            isLoadingMore: false,
            canLoadMore: true,
            nextOffset: nil,
            error: nil
        )
    }

    func resetHistoryPaginationContext(chatId: Int64) {
        historyPaginationStateByChatId[chatId] = HistoryPaginationContextState(
            items: [],
            isLoadingMore: false,
            canLoadMore: true,
            nextOffset: nil,
            error: nil
        )
    }

    func syncHistoryPaginationCanLoadMore(chatId: Int64) {
        var state = historyPaginationState(chatId: chatId)
        state.canLoadMore = !reachedHistoryStart.contains(chatId)
        if !state.canLoadMore {
            state.isLoadingMore = false
            state.nextOffset = nil
        }
        historyPaginationStateByChatId[chatId] = state
    }

    func markHistoryPaginationRequestQueued(chatId: Int64) {
        var state = historyPaginationState(chatId: chatId)
        state.isLoadingMore = true
        state.error = nil
        state.canLoadMore = !reachedHistoryStart.contains(chatId)
        historyPaginationStateByChatId[chatId] = state
    }

    func resolvedHistoryAnchor(chatId: Int64, requestedAnchorMessageId: Int64) -> Int64 {
        let cursorAnchor = historyPaginationState(chatId: chatId).nextOffset ?? 0

        // Cursor is the source of truth for contiguous pagination.
        // UI anchors can lag behind or jump during async merges/restores.
        if cursorAnchor > 0 {
            return cursorAnchor
        }
        return max(0, requestedAnchorMessageId)
    }

    func applyHistoryPaginationResponse(
        job: HistoryJob,
        responseMessages: [TGMessage],
        mergedMessages: [TGMessage]
    ) {
        var state = historyPaginationState(chatId: job.chatId)

        if !mergedMessages.isEmpty {
            var existingIds = Set(state.items)
            for message in mergedMessages where message.id > 0 {
                if existingIds.contains(message.id) {
                    continue
                }
                existingIds.insert(message.id)
                state.items.append(message.id)
            }
            if state.items.count > 6_000 {
                state.items.removeFirst(state.items.count - 6_000)
            }
        }

        let mergedOldest = mergedMessages
            .map(\.id)
            .filter { $0 > 0 }
            .min()
        let returnedOldest = responseMessages
            .map(\.id)
            .filter { $0 > 0 }
            .min()

        if let mergedOldest {
            state.nextOffset = mergedOldest
        } else if job.kind == .older {
            if let returnedOldest, returnedOldest < job.anchorMessageId {
                state.nextOffset = returnedOldest
            }
        } else if let returnedOldest {
            state.nextOffset = returnedOldest
        }

        state.isLoadingMore = false
        state.error = nil
        state.canLoadMore = !reachedHistoryStart.contains(job.chatId)
        if !state.canLoadMore {
            state.nextOffset = nil
        }

        historyPaginationStateByChatId[job.chatId] = state
    }

    func applyHistoryPaginationError(extra: String, message: String) {
        guard let job = historyJobs[extra] else {
            return
        }
        var state = historyPaginationState(chatId: job.chatId)
        state.isLoadingMore = false
        state.error = message
        state.canLoadMore = !reachedHistoryStart.contains(job.chatId)
        if !state.canLoadMore {
            state.nextOffset = nil
        }
        historyPaginationStateByChatId[job.chatId] = state
    }
}
