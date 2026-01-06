//  TelegramStore+Storage.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func _refreshStorageStatistics_impl() {
        let extra = "storage:full:\(UUID().uuidString)"
        storageExtrasInFlight.insert(extra)

        let req: [String: Any] = [
            "@type": "getStorageStatistics",
            "@extra": extra,
            "chat_limit": 0
        ]
        sendJSON(req)
    }

    func _applyCacheLimitBytes_impl(_ bytes: Int64) {
        let clamped = max(0, bytes)
        cacheLimitBytes = clamped
        UserDefaults.standard.set(NSNumber(value: clamped), forKey: cacheLimitBytesKey)
        optimizeStorage(maxBytes: clamped)
    }

    func _clearAllCache_impl() {
        optimizeStorage(maxBytes: 0)
    }

    func optimizeStorage(maxBytes: Int64) {
        let extra = "storage:optimize:\(UUID().uuidString)"
        storageExtrasInFlight.insert(extra)

        let fileTypes: [[String: Any]] = [
            ["@type": "fileTypePhoto"],
            ["@type": "fileTypeVideo"],
            ["@type": "fileTypeAnimation"],
            ["@type": "fileTypeDocument"],
            ["@type": "fileTypeAudio"],
            ["@type": "fileTypeVoiceNote"],
            ["@type": "fileTypeVideoNote"],
            ["@type": "fileTypeSticker"],
            ["@type": "fileTypeWallpaper"],
            ["@type": "fileTypeProfilePhoto"],
            ["@type": "fileTypeThumbnail"],
            ["@type": "fileTypeTemp"],
            ["@type": "fileTypeUnknown"]
        ]

        let req: [String: Any] = [
            "@type": "optimizeStorage",
            "@extra": extra,
            "size": maxBytes,
            "ttl": 0,
            "count": 0,
            "immunity_delay": 0,
            "file_types": fileTypes,
            "chat_ids": [],
            "exclude_chat_ids": [],
            "return_deleted_file_statistics": false,
            "chat_limit": 0
        ]

        sendJSON(req)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStorageStatistics()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshStorageStatistics()
        }
    }

    struct ParsedStorageStatistics {
        let extra: String?
        let byFileType: [StorageFileTypeStat]
    }

    func parseStorageStatisticsAny(_ upd: String) -> ParsedStorageStatistics? {
        guard let obj = parseJSON(upd) else { return nil }
        guard let type = obj["@type"] as? String else { return nil }

        let extra = obj["@extra"] as? String

        if type == "error" {
            if let extra { storageExtrasInFlight.remove(extra) }
            return nil
        }

        if type == "ok" {
            if let extra { storageExtrasInFlight.remove(extra) }
            return nil
        }

        func extraIsAcceptableForStorage() -> Bool {
            if storageExtrasInFlight.isEmpty { return true }
            guard let extra else { return true }
            return storageExtrasInFlight.contains(extra)
        }

        if type == "storageStatisticsFast" {
            guard extraIsAcceptableForStorage() else { return nil }

            let files = (obj["files_size"] as? NSNumber)?.int64Value ?? 0
            let db = (obj["database_size"] as? NSNumber)?.int64Value ?? 0
            let lpdb = (obj["language_pack_database_size"] as? NSNumber)?.int64Value ?? 0
            let log = (obj["log_size"] as? NSNumber)?.int64Value ?? 0

            let stats: [StorageFileTypeStat] = [
                StorageFileTypeStat(fileTypeKey: "fastFiles", bytes: files, count: 0),
                StorageFileTypeStat(fileTypeKey: "fastDatabase", bytes: db, count: 0),
                StorageFileTypeStat(fileTypeKey: "fastLanguagePackDatabase", bytes: lpdb, count: 0),
                StorageFileTypeStat(fileTypeKey: "fastLog", bytes: log, count: 0)
            ].filter { $0.bytes > 0 }

            return ParsedStorageStatistics(extra: extra, byFileType: mergeAndSortStorage(stats))
        }

        if type == "storageStatistics" {
            guard extraIsAcceptableForStorage() else { return nil }

            let byChatAny = (obj["by_chat"] as? [Any]) ?? []
            let byChat = byChatAny.compactMap { $0 as? [String: Any] }

            var acc: [String: StorageFileTypeStat] = [:]
            for c in byChat {
                let byTypeAny = (c["by_file_type"] as? [Any]) ?? []
                let byType = byTypeAny
                    .compactMap { $0 as? [String: Any] }
                    .compactMap(parseStorageByFileType(_:))
                for s in byType {
                    acc[s.fileTypeKey] = (acc[s.fileTypeKey] ?? s).adding(bytes: s.bytes, count: s.count)
                }
            }

            return ParsedStorageStatistics(extra: extra, byFileType: mergeAndSortStorage(Array(acc.values)))
        }

        return nil
    }

    func applyStorageStatistics(_ parsed: ParsedStorageStatistics) {
        if let extra = parsed.extra {
            storageExtrasInFlight.remove(extra)
        }

        storageByFileType = parsed.byFileType
        storageTotalBytes = parsed.byFileType.reduce(0) { $0 + $1.bytes }
        storageLastRefreshedAt = Date()
    }

    func parseStorageByFileType(_ obj: [String: Any]) -> StorageFileTypeStat? {
        guard let ft = obj["file_type"] as? [String: Any],
              let ftType = ft["@type"] as? String else { return nil }

        let bytes = (obj["size"] as? NSNumber)?.int64Value ?? 0
        let count = (obj["count"] as? NSNumber)?.int32Value ?? 0

        return StorageFileTypeStat(fileTypeKey: ftType, bytes: bytes, count: count)
    }

    func mergeAndSortStorage(_ stats: [StorageFileTypeStat]) -> [StorageFileTypeStat] {
        var acc: [String: StorageFileTypeStat] = [:]
        for s in stats {
            acc[s.fileTypeKey] = (acc[s.fileTypeKey] ?? s).adding(bytes: s.bytes, count: s.count)
        }
        return acc.values.sorted { $0.bytes > $1.bytes }
    }

    struct StorageFileTypeStat: Identifiable, Hashable {
        let fileTypeKey: String
        let bytes: Int64
        let count: Int32

        var id: String { fileTypeKey }

        var title: String {
            switch fileTypeKey {
            case "fastFiles": return "Кэш"
            case "fastDatabase": return "База данных"
            case "fastLanguagePackDatabase": return "Языки"
            case "fastLog": return "Логи"
            case "fileTypeVideo", "fileTypeVideoNote", "fileTypeAnimation": return "Видео"
            case "fileTypePhoto": return "Фото"
            case "fileTypeSticker": return "Стикеры"
            case "fileTypeAudio": return "Музыка"
            case "fileTypeVoiceNote": return "Спикеры"
            case "fileTypeDocument": return "Файлы"
            case "fileTypeProfilePhoto": return "Аватары"
            case "fileTypeThumbnail": return "Миниатюры"
            case "fileTypeWallpaper": return "Обои"
            case "fileTypeTemp": return "Временные"
            case "fileTypeDatabase": return "База сообщений"
            case "fileTypeUnknown": return "Кэш (всего)"
            default: return "Другое"
            }
        }

        var humanBytes: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        func adding(bytes addBytes: Int64, count addCount: Int32) -> StorageFileTypeStat {
            StorageFileTypeStat(fileTypeKey: fileTypeKey, bytes: self.bytes + addBytes, count: self.count + addCount)
        }
    }

    struct StorageBucket: Identifiable, Hashable {
        let title: String
        let bytes: Int64

        var id: String { title }

        var humanBytes: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    var storageBuckets: [StorageBucket] {
        var acc: [String: Int64] = [:]

        func bucketTitle(for fileTypeKey: String) -> String {
            switch fileTypeKey {
            case "fastFiles": return "Кэш"
            case "fastDatabase": return "База данных"
            case "fastLanguagePackDatabase": return "Языки"
            case "fastLog": return "Логи"
            case "fileTypeVideo", "fileTypeVideoNote", "fileTypeAnimation": return "Видео"
            case "fileTypePhoto": return "Фото"
            case "fileTypeAudio": return "Музыка"
            case "fileTypeVoiceNote": return "Спикеры"
            case "fileTypeSticker": return "Стикеры"
            case "fileTypeThumbnail", "fileTypeProfilePhoto", "fileTypeWallpaper": return "Прочее"
            case "fileTypeDatabase": return "База сообщений"
            case "fileTypeUnknown": return "Кэш (всего)"
            case "fileTypeTemp": return "Прочее"
            default: return "Другое"
            }
        }

        for s in storageByFileType {
            let t = bucketTitle(for: s.fileTypeKey)
            acc[t, default: 0] += s.bytes
        }

        return acc
            .map { StorageBucket(title: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    var clearableCacheBytes: Int64 {
        if let fast = storageByFileType.first(where: { $0.fileTypeKey == "fastFiles" }) {
            return fast.bytes
        }
        return storageTotalBytes
    }
}
