//  ThumbnailService.swift
//  Aurora
//

import Foundation
import AppKit
import OSLog

nonisolated final class ThumbnailService {
    private let thumbsDirURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aurora/thumbs", isDirectory: true)
        thumbsDirURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func ensureThumbnail(
        sourcePath: String,
        fileId: Int32,
        kind: String,
        maxPixel: Int,
        jpegQuality: CGFloat
    ) -> String? {
        AuroraImageThumb.ensureThumbnail(
            sourcePath: sourcePath,
            cacheDirURL: thumbsDirURL,
            fileId: fileId,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: jpegQuality
        )
    }
}

actor MediaService {
    typealias DownloadScheduler = (Int32, Int, String) -> Void
    typealias StatePublisher = @MainActor (TGMessageMediaKey, TGMediaState?) -> Void

    private struct FileSnapshot {
        let fileId: Int32
        let localPath: String?
        let downloadedSize: Int64
        let expectedSize: Int64
        let isDownloadingActive: Bool
        let isDownloadingCompleted: Bool

        var progress: Double? {
            guard expectedSize > 0 else { return nil }
            let normalized = Double(downloadedSize) / Double(expectedSize)
            return min(max(normalized, 0), 1)
        }
    }

    private struct SourceCandidate {
        let path: String
        let fileId: Int32
        let fromThumbnail: Bool
    }

    private let log = Logger(subsystem: "com.aurora.app", category: "media.service")
    private let thumbnailService = ThumbnailService()
    private let imageMemCache = ImageMemCache(countLimit: 384)
    private let scheduleDownload: DownloadScheduler
    private let publishState: StatePublisher
    private let thumbMaxPixelNormal = 520
    private let thumbMaxPixelLightweight = 280

    private var descriptorByKey: [TGMessageMediaKey: TGMessageMediaDescriptor] = [:]
    private var stateByKey: [TGMessageMediaKey: TGMediaState] = [:]
    private var thumbPathByKey: [TGMessageMediaKey: String] = [:]
    private var preferThumbOnlyByKey: [TGMessageMediaKey: Bool] = [:]
    private var fileStateById: [Int32: TGFileUpdate] = [:]
    private var keysByFileId: [Int32: Set<TGMessageMediaKey>] = [:]
    private var requestedDownloadFileIds: Set<Int32> = []

    init(
        scheduleDownload: @escaping DownloadScheduler,
        publishState: @escaping StatePublisher
    ) {
        self.scheduleDownload = scheduleDownload
        self.publishState = publishState
    }

    func reset() async {
        descriptorByKey.removeAll(keepingCapacity: false)
        stateByKey.removeAll(keepingCapacity: false)
        thumbPathByKey.removeAll(keepingCapacity: false)
        preferThumbOnlyByKey.removeAll(keepingCapacity: false)
        fileStateById.removeAll(keepingCapacity: false)
        keysByFileId.removeAll(keepingCapacity: false)
        requestedDownloadFileIds.removeAll(keepingCapacity: false)
        imageMemCache.clear()
    }

    func clear(chatId: Int64) async {
        let keysToRemove = descriptorByKey.keys.filter { $0.chatId == chatId }
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            descriptorByKey.removeValue(forKey: key)
            stateByKey.removeValue(forKey: key)
            thumbPathByKey.removeValue(forKey: key)
            preferThumbOnlyByKey.removeValue(forKey: key)
        }
        for fileId in keysByFileId.keys {
            guard var keys = keysByFileId[fileId] else { continue }
            keys.subtract(keysToRemove)
            if keys.isEmpty {
                keysByFileId.removeValue(forKey: fileId)
            } else {
                keysByFileId[fileId] = keys
            }
        }
        await MainActor.run {
            for key in keysToRemove {
                publishState(key, nil)
            }
        }
    }

    func ensureThumbnail(
        chatId: Int64,
        messageId: Int64,
        descriptor: TGMessageMediaDescriptor,
        preferThumbnailOnly: Bool
    ) async -> TGMediaState {
        let key = TGMessageMediaKey(chatId: chatId, messageId: messageId)
        return await ensureThumbnail(
            key: key,
            descriptor: descriptor,
            preferThumbnailOnly: preferThumbnailOnly,
            countRequest: true
        )
    }

    func handleFileUpdate(_ fileUpdate: TGFileUpdate) async {
        guard fileUpdate.fileId > 0 else { return }
        fileStateById[fileUpdate.fileId] = fileUpdate
        if fileUpdate.isDownloadingCompleted || !fileUpdate.isDownloadingActive {
            requestedDownloadFileIds.remove(fileUpdate.fileId)
        }

        guard let keys = keysByFileId[fileUpdate.fileId], !keys.isEmpty else { return }
        for key in keys {
            guard let descriptor = descriptorByKey[key] else { continue }
            let preferThumbOnly = preferThumbOnlyByKey[key] ?? false
            _ = await ensureThumbnail(
                key: key,
                descriptor: descriptor,
                preferThumbnailOnly: preferThumbOnly,
                countRequest: false
            )
        }
    }

    private func ensureThumbnail(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        preferThumbnailOnly: Bool,
        countRequest: Bool
    ) async -> TGMediaState {
        descriptorByKey[key] = descriptor
        preferThumbOnlyByKey[key] = preferThumbnailOnly
        registerFiles(for: key, descriptor: descriptor)
        seedFileState(from: descriptor.thumbnail)
        seedFileState(from: descriptor.media)

        if countRequest {
            ChatPerfTrace.recordMediaThumbRequest(chatId: key.chatId)
        }

        let resolvedPath: String?
        if let cachedPath = resolveReadyPath(for: key) {
            resolvedPath = cachedPath
        } else {
            resolvedPath = await prepareThumbnailIfPossible(
                key: key,
                descriptor: descriptor,
                preferThumbnailOnly: preferThumbnailOnly
            )
        }

        scheduleDownloadsIfNeeded(
            key: key,
            descriptor: descriptor,
            preferThumbnailOnly: preferThumbnailOnly,
            resolvedPath: resolvedPath
        )

        let state = buildState(
            key: key,
            descriptor: descriptor,
            resolvedPath: resolvedPath,
            preferThumbnailOnly: preferThumbnailOnly
        )
        await publishIfNeeded(state, for: key)
        return state
    }

    private func registerFiles(for key: TGMessageMediaKey, descriptor: TGMessageMediaDescriptor) {
        for fileId in descriptor.fileIds where fileId > 0 {
            var keys = keysByFileId[fileId] ?? Set<TGMessageMediaKey>()
            keys.insert(key)
            keysByFileId[fileId] = keys
        }
    }

    private func seedFileState(from descriptorFile: TGMessageMediaFile?) {
        guard let descriptorFile, descriptorFile.fileId > 0 else { return }
        guard fileStateById[descriptorFile.fileId] == nil else { return }
        fileStateById[descriptorFile.fileId] = TGFileUpdate(
            fileId: descriptorFile.fileId,
            localPath: descriptorFile.localPath,
            downloadedSize: descriptorFile.downloadedSize,
            expectedSize: descriptorFile.expectedSize,
            isDownloadingActive: descriptorFile.isDownloadingActive,
            isDownloadingCompleted: descriptorFile.isDownloadingCompleted
        )
    }

    private func resolveReadyPath(for key: TGMessageMediaKey) -> String? {
        guard let current = thumbPathByKey[key], fileExists(path: current) else { return nil }
        return current
    }

    private func prepareThumbnailIfPossible(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        preferThumbnailOnly: Bool
    ) async -> String? {
        guard let source = chooseSourceCandidate(
            descriptor: descriptor,
            preferThumbnailOnly: preferThumbnailOnly
        ) else {
            return nil
        }

        let maxPixel = preferThumbnailOnly ? thumbMaxPixelLightweight : thumbMaxPixelNormal
        let kind = descriptor.kind == .photo ? "message_photo" : "message_video"
        let memKey = "\(source.path)|\(kind)|\(maxPixel)" as NSString

        if imageMemCache.image(forKey: memKey) != nil {
            ChatPerfTrace.recordMediaThumbCacheHit(chatId: key.chatId, cacheHit: true)
            if let existing = thumbPathByKey[key], fileExists(path: existing) {
                return existing
            }
        } else {
            ChatPerfTrace.recordMediaThumbCacheHit(chatId: key.chatId, cacheHit: false)
        }

        let traceEnabled = ChatPerfTrace.isEnabled(for: key.chatId)
        let decodeStartNs = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0

        var thumbPath = thumbnailService.ensureThumbnail(
            sourcePath: source.path,
            fileId: source.fileId,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: preferThumbnailOnly ? 0.86 : 0.9
        )
        if thumbPath == nil && source.fromThumbnail {
            thumbPath = source.path
        }
        if thumbPath == nil && !preferThumbnailOnly {
            thumbPath = source.path
        }

        if traceEnabled {
            let durationMs = ChatPerfTrace.elapsedMs(since: decodeStartNs)
            ChatPerfTrace.recordMediaDecode(chatId: key.chatId, durationMs: durationMs)
        }

        guard let thumbPath, fileExists(path: thumbPath) else { return nil }
        if let image = NSImage(contentsOfFile: thumbPath) {
            imageMemCache.setImage(image, forKey: memKey)
        }
        thumbPathByKey[key] = thumbPath
        return thumbPath
    }

    private func chooseSourceCandidate(
        descriptor: TGMessageMediaDescriptor,
        preferThumbnailOnly: Bool
    ) -> SourceCandidate? {
        if let thumb = fileSnapshot(from: descriptor.thumbnail),
           let thumbPath = normalizedPath(thumb.localPath) {
            return SourceCandidate(path: thumbPath, fileId: thumb.fileId, fromThumbnail: true)
        }

        guard !preferThumbnailOnly else { return nil }
        if let media = fileSnapshot(from: descriptor.media),
           let mediaPath = normalizedPath(media.localPath) {
            return SourceCandidate(path: mediaPath, fileId: media.fileId, fromThumbnail: false)
        }
        return nil
    }

    private func scheduleDownloadsIfNeeded(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        preferThumbnailOnly: Bool,
        resolvedPath: String?
    ) {
        if resolvedPath != nil { return }

        if let thumbSnapshot = fileSnapshot(from: descriptor.thumbnail),
           thumbSnapshot.localPath == nil,
           !thumbSnapshot.isDownloadingCompleted {
            requestDownloadIfNeeded(
                fileId: thumbSnapshot.fileId,
                priority: 24,
                reason: "media-thumb:\(key.chatId):\(key.messageId)"
            )
        }

        guard !preferThumbnailOnly else { return }
        guard descriptor.thumbnail == nil else { return }
        if let mediaSnapshot = fileSnapshot(from: descriptor.media),
           mediaSnapshot.localPath == nil,
           !mediaSnapshot.isDownloadingCompleted {
            requestDownloadIfNeeded(
                fileId: mediaSnapshot.fileId,
                priority: 18,
                reason: "media-file:\(key.chatId):\(key.messageId)"
            )
        }
    }

    private func requestDownloadIfNeeded(fileId: Int32, priority: Int, reason: String) {
        guard fileId > 0 else { return }
        guard !requestedDownloadFileIds.contains(fileId) else { return }
        requestedDownloadFileIds.insert(fileId)
        scheduleDownload(fileId, priority, reason)
    }

    private func buildState(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        resolvedPath: String?,
        preferThumbnailOnly: Bool
    ) -> TGMediaState {
        let thumbnailState = fileSnapshot(from: descriptor.thumbnail)
        let mediaState = fileSnapshot(from: descriptor.media)
        let progress = thumbnailState?.progress ?? mediaState?.progress
        let anyActive = (thumbnailState?.isDownloadingActive ?? false) || (mediaState?.isDownloadingActive ?? false)
        let hasPendingPrimary: Bool = {
            if let thumbnailState {
                return thumbnailState.localPath == nil && !thumbnailState.isDownloadingCompleted
            }
            guard !preferThumbnailOnly else { return false }
            if let mediaState {
                return mediaState.localPath == nil && !mediaState.isDownloadingCompleted
            }
            return false
        }()
        let isLoading = anyActive || (resolvedPath == nil && hasPendingPrimary)
        return TGMediaState(thumbnailPath: resolvedPath, progress: progress, isLoading: isLoading)
    }

    private func fileSnapshot(from descriptorFile: TGMessageMediaFile?) -> FileSnapshot? {
        guard let descriptorFile else { return nil }
        if let updated = fileStateById[descriptorFile.fileId] {
            return FileSnapshot(
                fileId: updated.fileId,
                localPath: updated.localPath,
                downloadedSize: updated.downloadedSize,
                expectedSize: updated.expectedSize,
                isDownloadingActive: updated.isDownloadingActive,
                isDownloadingCompleted: updated.isDownloadingCompleted
            )
        }
        return FileSnapshot(
            fileId: descriptorFile.fileId,
            localPath: normalizedPath(descriptorFile.localPath),
            downloadedSize: descriptorFile.downloadedSize,
            expectedSize: descriptorFile.expectedSize,
            isDownloadingActive: descriptorFile.isDownloadingActive,
            isDownloadingCompleted: descriptorFile.isDownloadingCompleted
        )
    }

    private func normalizedPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        guard fileExists(path: path) else { return nil }
        return path
    }

    private func fileExists(path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func publishIfNeeded(_ state: TGMediaState, for key: TGMessageMediaKey) async {
        if stateByKey[key] == state {
            return
        }
        stateByKey[key] = state
        await MainActor.run {
            publishState(key, state)
        }
#if DEBUG
        if ChatPerfTrace.isEnabled(for: key.chatId), state.thumbnailPath == nil, state.isLoading {
            log.debug(
                "media pending chatId=\(key.chatId, privacy: .public) messageId=\(key.messageId, privacy: .public) progress=\(state.progress ?? -1, privacy: .public)"
            )
        }
#endif
    }
}
