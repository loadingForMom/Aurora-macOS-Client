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
            print("Missing TELEGRAM_API_ID / TELEGRAM_API_HASH in Config.swift")
            return false
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("Aurora/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let filesDir = appSupport.appendingPathComponent("Aurora/tdlib-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        guard let encryptionKey = getOrCreateDatabaseEncryptionKey() else {
            print("Failed to resolve TDLib database encryption key")
            return false
        }

#if DEBUG
        print("[TDLib] setTdlibParameters database_directory=\(dbDir.path) files_directory=\(filesDir.path) use_message_database=true use_chat_info_database=true use_file_database=true")
#endif

        let req: [String: Any] = [
            "@type": "setTdlibParameters",
            // TDLib docs: setTdlibParameters requires persistent database_directory and use_message_database.
            "database_directory": dbDir.path,
            // TDLib docs: optional files_directory for downloads/cache consistency.
            "files_directory": filesDir.path,
            // TDLib docs: database_encryption_key must be stable across launches.
            "database_encryption_key": encryptionKey,
            "use_message_database": true,
            "use_chat_info_database": true,
            "use_file_database": true,
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

    private func getOrCreateDatabaseEncryptionKey() -> String? {
        if let existing = fetchKeychainValue() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }

        let data = Data(bytes)
        let value = data.base64EncodedString()
        guard storeKeychainValue(value) else { return nil }
        return value
    }

    private func fetchKeychainValue() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.aurora.tdlib",
            kSecAttrAccount: "tdlib_database_encryption_key",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func storeKeychainValue(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.aurora.tdlib",
            kSecAttrAccount: "tdlib_database_encryption_key"
        ]

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }
}
