//
//  TDLibClient.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import OSLog

protocol TDLibClientType: AnyObject {
    func send(function: [String: Any], priority: TDLibClient.SendPriority)
    func makeReceiver() -> TDLibReceiver?
    func send(_ json: String, priority: TDLibClient.SendPriority)
    func stop()
}

extension TDLibClientType {
    func send(function: [String: Any]) {
        send(function: function, priority: .high)
    }

    func send(_ json: String) {
        send(json, priority: .high)
    }
}

final class TDLibClient: TDLibClientType {
    enum SendPriority: String {
        case high
        case low
    }

    private struct PendingSendQueue {
        private var storage: [String] = []
        private var head: Int = 0

        var isEmpty: Bool { head >= storage.count }

        mutating func enqueue(_ json: String) {
            storage.append(json)
        }

        mutating func dequeue() -> String? {
            guard head < storage.count else {
                storage.removeAll(keepingCapacity: false)
                head = 0
                return nil
            }
            let json = storage[head]
            head += 1
            if head > 64, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return json
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
            head = 0
        }
    }

    private let log = Logger(subsystem: "com.aurora.app", category: "tdlib.client")
    // Keep send isolated from receive loop and arbitrate high/low channels explicitly.
    private let sendQueue = DispatchQueue(label: "tdlib.send.queue")
    private var pendingHigh = PendingSendQueue()
    private var pendingLow = PendingSendQueue()

    private var client: UnsafeMutableRawPointer?

    init() {
        client = td_json_client_create()
        send(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":2}"#)
    }

    deinit {
        stop()
    }

    func send(function: [String: Any], priority: SendPriority = .high) {
        guard JSONSerialization.isValidJSONObject(function),
              let data = try? JSONSerialization.data(withJSONObject: function),
              let json = String(data: data, encoding: .utf8)
        else { return }
        send(json, priority: priority)
    }

    func makeReceiver() -> TDLibReceiver? {
        guard let client else { return nil }
        return TDLibReceiver(client: client)
    }

    func send(_ json: String, priority: SendPriority = .high) {
        sendQueue.async { [weak self] in
            guard let self, let client = self.client else { return }
            switch priority {
            case .high:
                self.pendingHigh.enqueue(json)
            case .low:
                self.pendingLow.enqueue(json)
            }
            self.drainPendingSends(client: client)
        }
    }

    func stop() {
        sendQueue.sync { [weak self] in
            guard let self, let client = self.client else { return }
            log.info("destroying tdlib client")
            self.pendingHigh.removeAll()
            self.pendingLow.removeAll()
            td_json_client_destroy(client)
            self.client = nil
        }
    }

    private func drainPendingSends(client: UnsafeMutableRawPointer) {
        while true {
            let next = pendingHigh.dequeue() ?? pendingLow.dequeue()
            guard let next else { return }
            next.withCString { td_json_client_send(client, $0) }
        }
    }
}

final class MockTDLibClient: TDLibClientType {
    func send(function: [String: Any], priority: TDLibClient.SendPriority) {
        _ = function
        _ = priority
    }

    func makeReceiver() -> TDLibReceiver? {
        nil
    }

    func send(_ json: String, priority: TDLibClient.SendPriority) {
        _ = json
        _ = priority
    }

    func stop() {}
}
