//  StorageManager.swift
//  Aurora
//

import Foundation

final class StorageManager {
    struct ParsedStorageStatistics {
        let extra: String?
        let byFileType: [TelegramStore.StorageFileTypeStat]
    }

    func makeStorageStatisticsRequest(extra: String) -> [String: Any] {
        [
            "@type": "getStorageStatistics",
            "@extra": extra,
            "chat_limit": 0
        ]
    }

    func makeOptimizeStorageRequest(extra: String, maxBytes: Int64) -> [String: Any] {
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
            ["@type": "fileTypeUnknown"]
        ]

        return [
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
    }

    func parseStorageStatisticsAny(
        _ upd: String,
        parseJSON: (String) -> [String: Any]?,
        storageExtrasInFlight: inout Set<String>
    ) -> ParsedStorageStatistics? {
        guard let obj = parseJSON(upd) else { return nil }
        guard let type = obj["@type"] as? String else { return nil }

        let extra = obj["@extra"] as? String

        if type == "error" || type == "ok" {
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

            let stats: [TelegramStore.StorageFileTypeStat] = [
                TelegramStore.StorageFileTypeStat(fileTypeKey: "fastFiles", bytes: files, count: 0),
                TelegramStore.StorageFileTypeStat(fileTypeKey: "fastDatabase", bytes: db, count: 0),
                TelegramStore.StorageFileTypeStat(fileTypeKey: "fastLanguagePackDatabase", bytes: lpdb, count: 0),
                TelegramStore.StorageFileTypeStat(fileTypeKey: "fastLog", bytes: log, count: 0)
            ].filter { $0.bytes > 0 }

            return ParsedStorageStatistics(extra: extra, byFileType: mergeAndSortStorage(stats))
        }

        if type == "storageStatistics" {
            guard extraIsAcceptableForStorage() else { return nil }

            let byChatAny = (obj["by_chat"] as? [Any]) ?? []
            let byChat = byChatAny.compactMap { $0 as? [String: Any] }

            var acc: [String: TelegramStore.StorageFileTypeStat] = [:]
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

    func parseStorageByFileType(_ obj: [String: Any]) -> TelegramStore.StorageFileTypeStat? {
        guard let ft = obj["file_type"] as? [String: Any],
              let ftType = ft["@type"] as? String else { return nil }

        let bytes = (obj["size"] as? NSNumber)?.int64Value ?? 0
        let count = (obj["count"] as? NSNumber)?.int32Value ?? 0

        return TelegramStore.StorageFileTypeStat(fileTypeKey: ftType, bytes: bytes, count: count)
    }

    func mergeAndSortStorage(_ stats: [TelegramStore.StorageFileTypeStat]) -> [TelegramStore.StorageFileTypeStat] {
        var acc: [String: TelegramStore.StorageFileTypeStat] = [:]
        for s in stats {
            acc[s.fileTypeKey] = (acc[s.fileTypeKey] ?? s).adding(bytes: s.bytes, count: s.count)
        }
        return acc.values.sorted { $0.bytes > $1.bytes }
    }

    func storageBuckets(from stats: [TelegramStore.StorageFileTypeStat]) -> [TelegramStore.StorageBucket] {
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

        for s in stats {
            let t = bucketTitle(for: s.fileTypeKey)
            acc[t, default: 0] += s.bytes
        }

        return acc
            .map { TelegramStore.StorageBucket(title: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    func clearableCacheBytes(from stats: [TelegramStore.StorageFileTypeStat], total: Int64) -> Int64 {
        if let fast = stats.first(where: { $0.fileTypeKey == "fastFiles" }) {
            return fast.bytes
        }
        return total
    }
}
