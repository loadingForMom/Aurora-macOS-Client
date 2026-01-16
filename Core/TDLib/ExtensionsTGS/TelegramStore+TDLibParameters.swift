//  TelegramStore+TDLibParameters.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func sendTdlibParametersIfPossible() -> Bool {
        let apiId = Config.apiId
        let apiHash = Config.apiHash
        guard apiId != 0, !apiHash.isEmpty else {
            print("Missing TELEGRAM_API_ID / TELEGRAM_API_HASH in Config.swift")
            return false
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("Aurora/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let req: [String: Any] = [
            "@type": "setTdlibParameters",
            "database_directory": dbDir.path,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": apiId,
            "api_hash": apiHash,
            "system_language_code": "en",
            "device_model": "Mac",
            "system_version": "macOS",
            "application_version": "0.2",
            "enable_storage_optimizer": true
        ]
        sendJSON(req)
        return true
    }
}

