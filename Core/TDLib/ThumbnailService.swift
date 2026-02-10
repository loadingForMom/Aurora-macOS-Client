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

    private enum RenderMode: Hashable, Sendable {
        case thumbnailOnly
        case bestForTarget
    }

    private struct RenderRequest: Hashable, Sendable {
        let mode: RenderMode
        let targetWidthPx: Int
        let targetHeightPx: Int
    }

    private struct ResolvedImage: Hashable, Sendable {
        let path: String
        let sourceFileId: Int32
        let selectedWidthPx: Int
        let selectedHeightPx: Int
        let maxPixel: Int
        let mode: RenderMode
    }

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
        let sizePx: CGSize?
    }

    private let log = Logger(subsystem: "com.aurora.app", category: "media.service")
    private let thumbnailService = ThumbnailService()
    private let imageMemCache = ImageMemCache(countLimit: 384)
    private let scheduleDownload: DownloadScheduler
    private let publishState: StatePublisher
    private let thumbMaxPixelLightweight = 280

    private var descriptorByKey: [TGMessageMediaKey: TGMessageMediaDescriptor] = [:]
    private var stateByKey: [TGMessageMediaKey: TGMediaState] = [:]
    private var resolvedImageByKey: [TGMessageMediaKey: ResolvedImage] = [:]
    private var requestByKey: [TGMessageMediaKey: RenderRequest] = [:]
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
        resolvedImageByKey.removeAll(keepingCapacity: false)
        requestByKey.removeAll(keepingCapacity: false)
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
            resolvedImageByKey.removeValue(forKey: key)
            requestByKey.removeValue(forKey: key)
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
        targetPointSize: CGSize,
        screenScale: CGFloat
    ) async -> TGMediaState {
        let key = TGMessageMediaKey(chatId: chatId, messageId: messageId)
        let request = Self.buildRequest(mode: .thumbnailOnly, targetPointSize: targetPointSize, screenScale: screenScale)
        return await ensureMedia(
            key: key,
            descriptor: descriptor,
            request: request,
            countRequest: true
        )
    }

    func ensureImage(
        chatId: Int64,
        messageId: Int64,
        descriptor: TGMessageMediaDescriptor,
        targetPointSize: CGSize,
        screenScale: CGFloat
    ) async -> TGMediaState {
        let key = TGMessageMediaKey(chatId: chatId, messageId: messageId)
        let request = Self.buildRequest(mode: .bestForTarget, targetPointSize: targetPointSize, screenScale: screenScale)
        return await ensureMedia(
            key: key,
            descriptor: descriptor,
            request: request,
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
            let request = requestByKey[key] ?? RenderRequest(mode: .thumbnailOnly, targetWidthPx: 240, targetHeightPx: 240)
            _ = await ensureMedia(
                key: key,
                descriptor: descriptor,
                request: request,
                countRequest: false
            )
        }
    }

    private func ensureMedia(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        request: RenderRequest,
        countRequest: Bool
    ) async -> TGMediaState {
        descriptorByKey[key] = descriptor
        requestByKey[key] = request
        registerFiles(for: key, descriptor: descriptor)
        seedFileState(from: descriptor.thumbnail)
        seedFileState(from: descriptor.media)
        for size in descriptor.photoSizes {
            seedFileState(from: size.file)
        }

        if countRequest {
            ChatPerfTrace.recordMediaThumbRequest(chatId: key.chatId)
        }

        let desired = computeDesiredSource(descriptor: descriptor, request: request)
        let selected = computeSelectedSource(descriptor: descriptor, request: request, desired: desired)
        let resolvedPath = await resolvePathIfPossible(
            key: key,
            descriptor: descriptor,
            request: request,
            desired: desired,
            selected: selected
        )

        scheduleDownloadsIfNeeded(
            key: key,
            descriptor: descriptor,
            request: request,
            desired: desired,
            selected: selected,
            resolvedPath: resolvedPath
        )

        let state = buildState(
            key: key,
            descriptor: descriptor,
            resolvedPath: resolvedPath,
            request: request,
            desired: desired,
            selected: selected
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

    private struct PlannedSource: Hashable, Sendable {
        let file: TGMessageMediaFile
        let widthPx: Int
        let heightPx: Int
        let isThumbnail: Bool
    }

    nonisolated private static func buildRequest(
        mode: RenderMode,
        targetPointSize: CGSize,
        screenScale: CGFloat
    ) -> RenderRequest {
        let scale = max(1, screenScale)
        let targetWidthPx = max(1, Int((targetPointSize.width * scale).rounded(.up)))
        let targetHeightPx = max(1, Int((targetPointSize.height * scale).rounded(.up)))
        return RenderRequest(mode: mode, targetWidthPx: targetWidthPx, targetHeightPx: targetHeightPx)
    }

    private func maxPixel(for request: RenderRequest) -> Int {
        let raw: Int = {
            switch request.mode {
            case .thumbnailOnly:
                return thumbMaxPixelLightweight
            case .bestForTarget:
                return max(request.targetWidthPx, request.targetHeightPx)
            }
        }()
        return max(32, raw)
    }

    nonisolated private func bestPhotoSize(
        forTargetWidthPx targetWidthPx: Int,
        sizes: [TGMessagePhotoSize]
    ) -> TGMessagePhotoSize? {
        guard !sizes.isEmpty else { return nil }
        for size in sizes where size.width >= targetWidthPx {
            return size
        }
        return sizes.last
    }

    private func computeDesiredSource(descriptor: TGMessageMediaDescriptor, request: RenderRequest) -> PlannedSource? {
        switch descriptor.kind {
        case .photo:
            let sizes = descriptor.photoSizes
            guard !sizes.isEmpty else {
                if let thumb = descriptor.thumbnail {
                    return PlannedSource(file: thumb, widthPx: descriptor.width, heightPx: descriptor.height, isThumbnail: true)
                }
                if let media = descriptor.media {
                    return PlannedSource(file: media, widthPx: descriptor.width, heightPx: descriptor.height, isThumbnail: false)
                }
                return nil
            }

            if request.mode == .thumbnailOnly {
                if let thumbId = descriptor.thumbnail?.fileId,
                   let thumbSize = sizes.first(where: { $0.file.fileId == thumbId }) {
                    return PlannedSource(
                        file: thumbSize.file,
                        widthPx: thumbSize.width,
                        heightPx: thumbSize.height,
                        isThumbnail: true
                    )
                }
                if let smallest = sizes.first {
                    return PlannedSource(file: smallest.file, widthPx: smallest.width, heightPx: smallest.height, isThumbnail: true)
                }
                return nil
            }

            guard let desiredSize = bestPhotoSize(forTargetWidthPx: request.targetWidthPx, sizes: sizes) else { return nil }
            let isThumb = desiredSize.file.fileId == descriptor.thumbnail?.fileId
            return PlannedSource(
                file: desiredSize.file,
                widthPx: desiredSize.width,
                heightPx: desiredSize.height,
                isThumbnail: isThumb
            )

        case .video:
            if let thumb = descriptor.thumbnail {
                return PlannedSource(file: thumb, widthPx: descriptor.width, heightPx: descriptor.height, isThumbnail: true)
            }
            if let media = descriptor.media {
                return PlannedSource(file: media, widthPx: descriptor.width, heightPx: descriptor.height, isThumbnail: false)
            }
            return nil
        }
    }

    private func computeSelectedSource(
        descriptor: TGMessageMediaDescriptor,
        request: RenderRequest,
        desired: PlannedSource?
    ) -> SourceCandidate? {
        _ = desired
        switch descriptor.kind {
        case .photo:
            let sizes = descriptor.photoSizes
            guard !sizes.isEmpty else {
                if let thumb = fileSnapshot(from: descriptor.thumbnail),
                   let thumbPath = normalizedPath(thumb.localPath) {
                    return SourceCandidate(
                        path: thumbPath,
                        fileId: thumb.fileId,
                        fromThumbnail: true,
                        sizePx: CGSize(width: descriptor.width, height: descriptor.height)
                    )
                }
                if let media = fileSnapshot(from: descriptor.media),
                   let mediaPath = normalizedPath(media.localPath) {
                    return SourceCandidate(
                        path: mediaPath,
                        fileId: media.fileId,
                        fromThumbnail: false,
                        sizePx: CGSize(width: descriptor.width, height: descriptor.height)
                    )
                }
                return nil
            }

            var candidates: [SourceCandidate] = []
            candidates.reserveCapacity(min(8, sizes.count))
            let thumbId = descriptor.thumbnail?.fileId
            for size in sizes {
                guard let snapshot = fileSnapshot(from: size.file) else { continue }
                guard let path = normalizedPath(snapshot.localPath) else { continue }
                let isThumb = (snapshot.fileId == thumbId)
                candidates.append(
                    SourceCandidate(
                        path: path,
                        fileId: snapshot.fileId,
                        fromThumbnail: isThumb,
                        sizePx: CGSize(width: size.width, height: size.height)
                    )
                )
            }
            guard !candidates.isEmpty else { return nil }
            candidates.sort { ($0.sizePx?.width ?? 0) < ($1.sizePx?.width ?? 0) }

            if request.mode == .thumbnailOnly {
                if let thumbId,
                   let thumbCandidate = candidates.first(where: { $0.fileId == thumbId }) {
                    return thumbCandidate
                }
                return candidates.first
            }

            for candidate in candidates {
                let width = Int(candidate.sizePx?.width ?? 0)
                if width >= request.targetWidthPx {
                    return candidate
                }
            }
            return candidates.last

        case .video:
            if let thumb = fileSnapshot(from: descriptor.thumbnail),
               let thumbPath = normalizedPath(thumb.localPath) {
                return SourceCandidate(
                    path: thumbPath,
                    fileId: thumb.fileId,
                    fromThumbnail: true,
                    sizePx: CGSize(width: descriptor.width, height: descriptor.height)
                )
            }

            guard let media = fileSnapshot(from: descriptor.media),
                  let mediaPath = normalizedPath(media.localPath)
            else { return nil }
            return SourceCandidate(
                path: mediaPath,
                fileId: media.fileId,
                fromThumbnail: false,
                sizePx: CGSize(width: descriptor.width, height: descriptor.height)
            )
        }
    }

    private func resolvePathIfPossible(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        request: RenderRequest,
        desired: PlannedSource?,
        selected: SourceCandidate?
    ) async -> String? {
        _ = desired
        let previousResolved: ResolvedImage? = {
            guard let resolved = resolvedImageByKey[key] else { return nil }
            guard fileExists(path: resolved.path) else {
                resolvedImageByKey.removeValue(forKey: key)
                return nil
            }
            return resolved
        }()

        if request.mode == .thumbnailOnly {
            if let previousResolved {
                return previousResolved.path
            }
            guard let selected else { return nil }

            let selectedMaxPixel = Int(max(selected.sizePx?.width ?? 0, selected.sizePx?.height ?? 0))
            let effectiveMaxPixel = max(32, min(thumbMaxPixelLightweight, max(1, selectedMaxPixel)))

            let kind = descriptor.kind == .photo ? "message_photo" : "message_video"
            let memKey = "\(selected.path)|\(kind)|\(effectiveMaxPixel)" as NSString

            if imageMemCache.image(forKey: memKey) != nil {
                ChatPerfTrace.recordMediaThumbCacheHit(chatId: key.chatId, cacheHit: true)
            } else {
                ChatPerfTrace.recordMediaThumbCacheHit(chatId: key.chatId, cacheHit: false)
            }

            var outputPath = thumbnailService.ensureThumbnail(
                sourcePath: selected.path,
                fileId: selected.fileId,
                kind: kind,
                maxPixel: effectiveMaxPixel,
                jpegQuality: 0.86
            )
            if outputPath == nil {
                outputPath = selected.path
            }
            guard let resolvedPath = outputPath, fileExists(path: resolvedPath) else { return nil }

            let newResolved = ResolvedImage(
                path: resolvedPath,
                sourceFileId: selected.fileId,
                selectedWidthPx: Int(selected.sizePx?.width ?? 0),
                selectedHeightPx: Int(selected.sizePx?.height ?? 0),
                maxPixel: effectiveMaxPixel,
                mode: request.mode
            )
            resolvedImageByKey[key] = newResolved

            if let image = NSImage(contentsOfFile: resolvedPath) {
                imageMemCache.setImage(image, forKey: memKey)
            }

            return resolvedPath
        }

        guard let selected else { return previousResolved?.path }

        let targetMaxPixel = maxPixel(for: request)
        let selectedMaxPixel = Int(max(selected.sizePx?.width ?? 0, selected.sizePx?.height ?? 0))
        let effectiveMaxPixel = max(32, min(targetMaxPixel, max(1, selectedMaxPixel)))

        if let previousResolved,
           previousResolved.mode == .bestForTarget,
           previousResolved.sourceFileId == selected.fileId,
           previousResolved.maxPixel >= effectiveMaxPixel,
           fileExists(path: previousResolved.path) {
            return previousResolved.path
        }

        let kind = descriptor.kind == .photo ? "message_photo" : "message_video"
        let memKey = "\(selected.path)|\(kind)|\(effectiveMaxPixel)" as NSString

        if imageMemCache.image(forKey: memKey) != nil {
            ChatPerfTrace.recordMediaThumbCacheHit(chatId: key.chatId, cacheHit: true)
            if let previousResolved, fileExists(path: previousResolved.path) {
                return previousResolved.path
            }
        } else {
            ChatPerfTrace.recordMediaThumbCacheHit(chatId: key.chatId, cacheHit: false)
        }

        let traceEnabled = ChatPerfTrace.isEnabled(for: key.chatId)
        let decodeStartNs = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0

        var outputPath = thumbnailService.ensureThumbnail(
            sourcePath: selected.path,
            fileId: selected.fileId,
            kind: kind,
            maxPixel: effectiveMaxPixel,
            jpegQuality: 0.92
        )
        if outputPath == nil {
            outputPath = selected.path
        }

        if traceEnabled {
            let durationMs = ChatPerfTrace.elapsedMs(since: decodeStartNs)
            ChatPerfTrace.recordMediaDecode(chatId: key.chatId, durationMs: durationMs)
        }

        guard let resolvedPath = outputPath, fileExists(path: resolvedPath) else {
            return previousResolved?.path
        }

        let newResolved = ResolvedImage(
            path: resolvedPath,
            sourceFileId: selected.fileId,
            selectedWidthPx: Int(selected.sizePx?.width ?? 0),
            selectedHeightPx: Int(selected.sizePx?.height ?? 0),
            maxPixel: effectiveMaxPixel,
            mode: request.mode
        )
        resolvedImageByKey[key] = newResolved

        if traceEnabled {
            let isThumb = selected.fromThumbnail
            let previousQuality: (Int, Int, Int) = {
                guard let previousResolved else { return (0, 0, 0) }
                let modeRank = previousResolved.mode == .bestForTarget ? 1 : 0
                return (modeRank, previousResolved.selectedWidthPx, previousResolved.maxPixel)
            }()
            let newQuality: (Int, Int, Int) = {
                let modeRank = newResolved.mode == .bestForTarget ? 1 : 0
                return (modeRank, newResolved.selectedWidthPx, newResolved.maxPixel)
            }()
            let isUpgraded = previousResolved != nil && newQuality > previousQuality
            ChatPerfTrace.recordMediaSelection(
                chatId: key.chatId,
                messageId: key.messageId,
                targetWidthPx: request.targetWidthPx,
                targetHeightPx: request.targetHeightPx,
                selectedWidthPx: newResolved.selectedWidthPx,
                selectedHeightPx: newResolved.selectedHeightPx,
                isThumb: isThumb,
                isUpgraded: isUpgraded
            )
        }

        if let image = NSImage(contentsOfFile: resolvedPath) {
            imageMemCache.setImage(image, forKey: memKey)
        }

        return resolvedPath
    }

    private func scheduleDownloadsIfNeeded(
        key: TGMessageMediaKey,
        descriptor: TGMessageMediaDescriptor,
        request: RenderRequest,
        desired: PlannedSource?,
        selected: SourceCandidate?,
        resolvedPath: String?
    ) {
        _ = selected
        let thumbSnapshot = fileSnapshot(from: descriptor.thumbnail)
        let desiredSnapshot: FileSnapshot? = desired.flatMap { fileSnapshot(from: $0.file) }

        if resolvedPath == nil,
           let thumbSnapshot,
           thumbSnapshot.localPath == nil,
           !thumbSnapshot.isDownloadingCompleted {
            requestDownloadIfNeeded(
                fileId: thumbSnapshot.fileId,
                priority: 24,
                reason: "media-thumb:\(key.chatId):\(key.messageId)"
            )
        }

        guard request.mode == .bestForTarget else { return }
        guard let desiredSnapshot else { return }
        if desiredSnapshot.localPath == nil,
           !desiredSnapshot.isDownloadingCompleted {
            requestDownloadIfNeeded(
                fileId: desiredSnapshot.fileId,
                priority: 18,
                reason: "media-best:\(key.chatId):\(key.messageId)"
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
        request: RenderRequest,
        desired: PlannedSource?,
        selected: SourceCandidate?
    ) -> TGMediaState {
        _ = key
        _ = request
        _ = selected

        let primarySnapshot: FileSnapshot? = desired.flatMap { fileSnapshot(from: $0.file) }
        let thumbnailSnapshot = fileSnapshot(from: descriptor.thumbnail)
        let mediaSnapshot = fileSnapshot(from: descriptor.media)

        let progress = primarySnapshot?.progress ?? thumbnailSnapshot?.progress ?? mediaSnapshot?.progress
        let anyActive = (primarySnapshot?.isDownloadingActive ?? false)
            || (thumbnailSnapshot?.isDownloadingActive ?? false)
            || (mediaSnapshot?.isDownloadingActive ?? false)
        let hasPendingPrimary = (primarySnapshot?.localPath == nil) && !(primarySnapshot?.isDownloadingCompleted ?? true)

        let isLoading = resolvedPath == nil && (anyActive || hasPendingPrimary)
        return TGMediaState(thumbnailPath: resolvedPath, progress: progress, isLoading: isLoading)
    }

    private func fileSnapshot(from descriptorFile: TGMessageMediaFile?) -> FileSnapshot? {
        guard let descriptorFile else { return nil }
        if let updated = fileStateById[descriptorFile.fileId] {
            return FileSnapshot(
                fileId: updated.fileId,
                localPath: normalizedPath(updated.localPath),
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
