//
//  TDLibReceiver.swift
//  Aurora
//

import Foundation
import OSLog

final class TDLibReceiver {
    private let log = Logger(subsystem: "com.aurora.app", category: "tdlib.receiver")
    private let client: UnsafeMutableRawPointer
    private var thread: Thread?
    private var isRunning = true

    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(client: UnsafeMutableRawPointer) {
        var cont: AsyncStream<String>.Continuation!
        stream = AsyncStream<String> { cont = $0 }
        continuation = cont
        self.client = client
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in
            self?.runLoop()
        }
        t.name = "TDLibReceiverThread"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        isRunning = false
    }

    private func runLoop() {
        log.info("receiver loop started")
        while isRunning {
            autoreleasepool {
                if let cstr = td_json_client_receive(client, 1.0) {
                    let json = String(cString: cstr)
                    continuation.yield(json)
                }
            }
        }
        continuation.finish()
        log.info("receiver loop stopped")
    }
}
