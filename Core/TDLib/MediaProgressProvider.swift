//
//  MediaProgressProvider.swift
//  Aurora
//

import Foundation
import Combine

final class MediaProgressProvider {
    final class Observer: ObservableObject {
        fileprivate let key: TGMessageMediaKey
        @Published private(set) var state: TGMediaState?

        fileprivate init(key: TGMessageMediaKey, state: TGMediaState?) {
            self.key = key
            self.state = state
        }

        fileprivate func apply(_ nextState: TGMediaState?) {
            guard state != nextState else { return }
            state = nextState
        }
    }

    private var stateByKey: [TGMessageMediaKey: TGMediaState] = [:]
    private var observerByKey: [TGMessageMediaKey: Observer] = [:]

    func observer(chatId: Int64, messageId: Int64) -> Observer {
        let key = TGMessageMediaKey(chatId: chatId, messageId: messageId)
        if let existing = observerByKey[key] {
            return existing
        }
        let created = Observer(key: key, state: stateByKey[key])
        observerByKey[key] = created
        return created
    }

    func state(chatId: Int64, messageId: Int64) -> TGMediaState? {
        stateByKey[TGMessageMediaKey(chatId: chatId, messageId: messageId)]
    }

    func setState(_ state: TGMediaState?, for key: TGMessageMediaKey) {
        let previous = stateByKey[key]
        guard previous != state else { return }
        if let state {
            stateByKey[key] = state
        } else {
            stateByKey.removeValue(forKey: key)
        }
        observerByKey[key]?.apply(state)
    }

    func clear(chatId: Int64) {
        let keys = Set(stateByKey.keys.filter { $0.chatId == chatId })
            .union(observerByKey.keys.filter { $0.chatId == chatId })
        guard !keys.isEmpty else { return }
        for key in keys {
            stateByKey.removeValue(forKey: key)
            observerByKey[key]?.apply(nil)
            observerByKey.removeValue(forKey: key)
        }
    }

    func reset() {
        for observer in observerByKey.values {
            observer.apply(nil)
        }
        observerByKey.removeAll(keepingCapacity: false)
        stateByKey.removeAll(keepingCapacity: false)
    }
}
