//  TelegramStore+Storage.swift
//  Aurora
//

import Foundation

extension TelegramStore {

    func _refreshStorageStatistics_impl() {
        let extra = "storage:full:\(UUID().uuidString)"
        storageExtrasInFlight.insert(extra)

        let req = storageManager.makeStorageStatisticsRequest(extra: extra)
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

        let req = storageManager.makeOptimizeStorageRequest(extra: extra, maxBytes: maxBytes)

        sendJSON(req)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStorageStatistics()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshStorageStatistics()
        }
    }

    func parseStorageStatisticsAny(_ upd: String) -> StorageManager.ParsedStorageStatistics? {
        storageManager.parseStorageStatisticsAny(
            upd,
            parseJSON: parseJSON,
            storageExtrasInFlight: &storageExtrasInFlight
        )
    }

    func applyStorageStatistics(_ parsed: StorageManager.ParsedStorageStatistics) {
        if let extra = parsed.extra {
            storageExtrasInFlight.remove(extra)
        }

        storageByFileType = parsed.byFileType
        storageTotalBytes = parsed.byFileType.reduce(0) { $0 + $1.bytes }
        storageLastRefreshedAt = Date()
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
        storageManager.storageBuckets(from: storageByFileType)
    }

    var clearableCacheBytes: Int64 {
        storageManager.clearableCacheBytes(from: storageByFileType, total: storageTotalBytes)
    }
}
