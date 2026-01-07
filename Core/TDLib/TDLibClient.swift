//
//  TDLibClient.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation

final class TDLibClient {
    // TDLib requirement: td_receive must be called from a single thread/queue.
    private let receiveQueue = DispatchQueue(label: "tdlib.receive.queue")
    // Send is lightweight; keep it off the receive loop so it doesn't get starved.
    private let sendQueue = DispatchQueue(label: "tdlib.send.queue")

    private var client: UnsafeMutableRawPointer?
    private var isRunning = false

    init() {
        client = td_json_client_create()
        send(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":2}"#)
    }

    deinit {
        stop()
        if let client {
            td_json_client_destroy(client)
        }
    }

    func send(function: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(function),
              let data = try? JSONSerialization.data(withJSONObject: function),
              let json = String(data: data, encoding: .utf8)
        else { return }
        send(json)
    }

    func receive(timeout: Double) -> String? {
        guard let client else { return nil }
        guard let cstr = td_json_client_receive(client, timeout) else { return nil }
        return String(cString: cstr)
    }

    func send(_ json: String) {
        sendQueue.async { [weak self] in
            guard let self, let client = self.client else { return }
            json.withCString { td_json_client_send(client, $0) }
        }
    }

    func startEventLoop(onUpdate: @escaping (String) -> Void, onResponse: @escaping (String) -> Void) {
        // Prevent accidental double-start.
        guard !isRunning else { return }
        isRunning = true

        receiveQueue.async { [weak self] in
            guard let self else { return }
            while self.isRunning {
                if let json = self.receive(timeout: 1.0) {
                    if self.isUpdate(json) {
                        onUpdate(json)
                    } else {
                        onResponse(json)
                    }
                }
            }
        }
    }

    func stop() {
        isRunning = false
    }

    private func isUpdate(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["@type"] as? String
        else { return false }
        return type.hasPrefix("update")
    }
}
