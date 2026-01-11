//
//  TDLibClient.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation
import OSLog

final class TDLibClient {
    private let log = Logger(subsystem: "com.aurora.app", category: "tdlib.client")
    // Send is lightweight; keep it off the receive loop so it doesn't get starved.
    private let sendQueue = DispatchQueue(label: "tdlib.send.queue")

    private var client: UnsafeMutableRawPointer?

    init() {
        client = td_json_client_create()
        send(#"{"@type":"setLogVerbosityLevel","new_verbosity_level":2}"#)
    }

    deinit {
        stop()
    }

    func send(function: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(function),
              let data = try? JSONSerialization.data(withJSONObject: function),
              let json = String(data: data, encoding: .utf8)
        else { return }
        send(json)
    }

    func makeReceiver() -> TDLibReceiver? {
        guard let client else { return nil }
        return TDLibReceiver(client: client)
    }

    func send(_ json: String) {
        sendQueue.async { [weak self] in
            guard let self, let client = self.client else { return }
            json.withCString { td_json_client_send(client, $0) }
        }
    }

    func stop() {
        guard let client else { return }
        log.info("destroying tdlib client")
        td_json_client_destroy(client)
        self.client = nil
    }
}
