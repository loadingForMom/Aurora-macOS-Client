//
//  Config.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import Foundation

enum Config {
    static var apiId: Int {
        Int(ProcessInfo.processInfo.environment["TELEGRAM_API_ID"] ?? "") ?? 0
    }

    static var apiHash: String {
        ProcessInfo.processInfo.environment["TELEGRAM_API_HASH"] ?? ""
    }
}
