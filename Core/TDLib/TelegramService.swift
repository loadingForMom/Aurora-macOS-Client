//
//  TelegramService.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation

final class TelegramService {
    private let td = TDLibClient()

    var onUpdate: ((String) -> Void)?

    func start() {
        td.startReceiveLoop { [weak self] upd in
            self?.onUpdate?(upd)
        }
    }

    func send(_ json: String) {
        td.send(json)
    }

    func sendJSON(_ obj: Any) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8)
        else { return }
        td.send(str)
    }
}
