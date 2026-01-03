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
        td_set_log_verbosity_level(2)
        client = td_json_client_create()
    }

    deinit {
        stop()
        if let client {
            td_json_client_destroy(client)
        }
    }

    func send(_ json: String) {
        sendQueue.async { [weak self] in
            guard let self, let client = self.client else { return }
            json.withCString { td_json_client_send(client, $0) }
        }
    }

    func startReceiveLoop(onUpdate: @escaping (String) -> Void) {
        // Prevent accidental double-start.
        guard !isRunning else { return }
        isRunning = true

        receiveQueue.async { [weak self] in
            guard let self else { return }
            while self.isRunning {
                guard let client = self.client else { return }
                if let cstr = td_json_client_receive(client, 1.0) {
                    onUpdate(String(cString: cstr))
                }
            }
        }
    }

    func stop() {
        isRunning = false
    }
}
