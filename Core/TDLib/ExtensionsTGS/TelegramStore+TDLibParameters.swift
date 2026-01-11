//  TelegramStore+TDLibParameters.swift
//  Aurora
//

import Foundation
import Security

extension TelegramStore {

    func sendTdlibParametersIfPossible() -> Bool {
        guard authState == "authorizationStateWaitTdlibParameters" else { return false }
        let apiId = Config.apiId
        let apiHash = Config.apiHash
        guard apiId != 0, !apiHash.isEmpty else {
            log.error("Missing TELEGRAM_API_ID / TELEGRAM_API_HASH in Config.swift")
            return false
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("Aurora/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let filesDir = appSupport.appendingPathComponent("Aurora/tdlib-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        guard let encryptionKey = getOrCreateDatabaseEncryptionKey() else {
            log.error("Failed to resolve TDLib database encryption key")
            return false
        }

#if DEBUG
        log.debug("setTdlibParameters database_directory=\(dbDir.path, privacy: .public) files_directory=\(filesDir.path, privacy: .public) use_message_database=false use_chat_info_database=false use_file_database=false")
#endif

        let req: [String: Any] = [
            "@type": "setTdlibParameters",
            // TDLib docs: setTdlibParameters requires persistent database_directory and use_message_database.
            "database_directory": dbDir.path,
            // TDLib docs: optional files_directory for downloads/cache consistency.
            "files_directory": filesDir.path,
            // TDLib docs: database_encryption_key must be stable across launches.
            "database_encryption_key": encryptionKey,
            "use_message_database": false,
            "use_chat_info_database": false,
            "use_file_database": false,
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

    func getOrCreateDatabaseEncryptionKey() -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let keyURL = appSupport.appendingPathComponent("Aurora/tdlib.key")
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return data.base64EncodedString()
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }

        let data = Data(bytes)
        do {
            try data.write(to: keyURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        } catch {
            log.error("Failed to store TDLib key: \(String(describing: error), privacy: .public)")
            return nil
        }
        return data.base64EncodedString()
    }
}
