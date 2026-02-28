//  AvatarService.swift
//  Aurora
//

import Foundation
import AppKit

nonisolated final class AvatarService: @unchecked Sendable {
    struct ChatAvatarMeta: Sendable {
        var smallFileId: Int32?
        var bigFileId: Int32?
        var smallPath: String?
        var bigPath: String?
    }

    private let imageMemCache = ImageMemCache()
    private let thumbnailService = ThumbnailService()
    private let avatarDecodeQueue = DispatchQueue(
        label: "com.aurora.app.avatar.decode",
        qos: .utility,
        attributes: .concurrent
    )

    private let defaultListThumbMaxPx: Int = 128
    private let defaultProfileThumbMaxPx: Int = 128
    private let defaultInspectorThumbMaxPx: Int = 1024
    private let defaultPosterThumbMaxPx: Int = 2048

    init() {
    }

    func clearMemoryCache() {
        imageMemCache.clear()
    }

    func screenScale() -> CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }

    func maxPixel(forPointSize pt: CGFloat, clampTo maxClamp: Int) -> Int {
        let px = Int((pt * screenScale()).rounded(.up))
        return min(max(32, px), maxClamp)
    }

    func myProfileNSImage(pointSize: CGFloat, profilePhotoPath: String?, myPhotoFileId: Int32?) -> NSImage? {
        guard let src = profilePhotoPath, !src.isEmpty else { return nil }
        let maxPx = maxPixel(forPointSize: pointSize, clampTo: defaultProfileThumbMaxPx)
        return loadOrMakeThumbNSImage(sourcePath: src,
                                      fileId: myPhotoFileId,
                                      kind: "me",
                                      maxPixel: maxPx,
                                      jpegQuality: 0.92)
    }

    func chatAvatarNSImage(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool,
        maxClamp: Int?,
        kindOverride: String?,
        chatAvatarMetaByChatId: [Int64: ChatAvatarMeta],
        chatAvatarPathByChatId: [Int64: String]
    ) -> NSImage? {
        let meta = chatAvatarMetaByChatId[chatId]
        let fallbackPath = chatAvatarPathByChatId[chatId]
        return chatAvatarNSImage(
            chatId: chatId,
            pointSize: pointSize,
            preferHiRes: preferHiRes,
            maxClamp: maxClamp,
            kindOverride: kindOverride,
            meta: meta,
            fallbackPath: fallbackPath
        )
    }

    func chatAvatarNSImage(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool,
        maxClamp: Int?,
        kindOverride: String?,
        meta: ChatAvatarMeta?,
        fallbackPath: String?
    ) -> NSImage? {
        let cap = maxClamp ?? (preferHiRes ? defaultInspectorThumbMaxPx : defaultListThumbMaxPx)
        let maxPx = maxPixel(forPointSize: pointSize, clampTo: cap)

        let src: String? = {
            if preferHiRes {
                if let p = meta?.bigPath, !p.isEmpty { return p }
                if let p = meta?.smallPath, !p.isEmpty { return p }
                return fallbackPath
            } else {
                if let p = meta?.smallPath, !p.isEmpty { return p }
                if let p = meta?.bigPath, !p.isEmpty { return p }
                return fallbackPath
            }
        }()

        guard let srcPath = src, !srcPath.isEmpty else { return nil }

        let fid: Int32? = {
            if preferHiRes { return meta?.bigFileId ?? meta?.smallFileId }
            return meta?.smallFileId ?? meta?.bigFileId
        }()

        let kind = kindOverride ?? (preferHiRes ? "chat_big" : "chat_small")
        let q: CGFloat = preferHiRes ? 0.92 : 0.88

        return loadOrMakeThumbNSImage(
            sourcePath: srcPath,
            fileId: fid,
            kind: kind,
            maxPixel: maxPx,
            jpegQuality: q
        )
    }

    func chatAvatarNSImageAsync(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool,
        maxClamp: Int?,
        kindOverride: String?,
        meta: ChatAvatarMeta?,
        fallbackPath: String?
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            avatarDecodeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = self.chatAvatarNSImage(
                    chatId: chatId,
                    pointSize: pointSize,
                    preferHiRes: preferHiRes,
                    maxClamp: maxClamp,
                    kindOverride: kindOverride,
                    meta: meta,
                    fallbackPath: fallbackPath
                )
                continuation.resume(returning: image)
            }
        }
    }

    func prefetchChatAvatarHiResIfNeeded(
        chatId: Int64,
        chatAvatarMetaByChatId: [Int64: ChatAvatarMeta],
        downloadFileIfNeeded: (Int32, Int) -> Void
    ) {
        guard let meta = chatAvatarMetaByChatId[chatId] else { return }
        guard let bigId = meta.bigFileId else { return }

        if let p = meta.bigPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            _ = loadOrMakeThumbNSImage(
                sourcePath: p,
                fileId: bigId,
                kind: "chat_big",
                maxPixel: defaultInspectorThumbMaxPx,
                jpegQuality: 0.92
            )

            _ = loadOrMakeThumbNSImage(
                sourcePath: p,
                fileId: bigId,
                kind: "chat_poster",
                maxPixel: defaultPosterThumbMaxPx,
                jpegQuality: 0.92
            )
            return
        }

        downloadFileIfNeeded(bigId, 10)
    }

    func registerChatAvatar(
        chatId: Int64,
        smallFileId: Int32?,
        bigFileId: Int32?,
        initialBestPath: String?,
        chatAvatarMetaByChatId: inout [Int64: ChatAvatarMeta],
        chatIdByAvatarFileId: inout [Int32: Int64]
    ) {
        if let previous = chatAvatarMetaByChatId[chatId] {
            if let previousSmall = previous.smallFileId, chatIdByAvatarFileId[previousSmall] == chatId {
                chatIdByAvatarFileId.removeValue(forKey: previousSmall)
            }
            if let previousBig = previous.bigFileId, chatIdByAvatarFileId[previousBig] == chatId {
                chatIdByAvatarFileId.removeValue(forKey: previousBig)
            }
        }

        var meta = chatAvatarMetaByChatId[chatId] ?? ChatAvatarMeta()
        meta.smallFileId = smallFileId
        meta.bigFileId = bigFileId

        if let p = initialBestPath, !p.isEmpty, FileManager.default.fileExists(atPath: p) {
            if meta.smallPath == nil { meta.smallPath = p }
            else if meta.bigPath == nil { meta.bigPath = p }
        }

        chatAvatarMetaByChatId[chatId] = meta

        if let sid = smallFileId {
            chatIdByAvatarFileId[sid] = chatId
        }

        if let bid = bigFileId {
            chatIdByAvatarFileId[bid] = chatId
            // don't auto-download big
        }
    }

    func applyChatAvatarFileUpdate(
        chatId: Int64,
        fileId: Int32,
        path: String,
        chatAvatarMetaByChatId: inout [Int64: ChatAvatarMeta]
    ) -> String? {
        guard var meta = chatAvatarMetaByChatId[chatId] else { return nil }

        if meta.smallFileId == fileId {
            meta.smallPath = path
        } else if meta.bigFileId == fileId {
            meta.bigPath = path
        } else {
            return meta.smallPath ?? meta.bigPath
        }

        chatAvatarMetaByChatId[chatId] = meta

        let best = (meta.smallPath?.isEmpty == false ? meta.smallPath : meta.bigPath)

        let isBig = (meta.bigFileId == fileId)

        _ = loadOrMakeThumbNSImage(
            sourcePath: path,
            fileId: fileId,
            kind: isBig ? "chat_big" : "chat_small",
            maxPixel: isBig ? defaultInspectorThumbMaxPx : defaultListThumbMaxPx,
            jpegQuality: isBig ? 0.94 : 0.88
        )

        if isBig {
            _ = loadOrMakeThumbNSImage(
                sourcePath: path,
                fileId: fileId,
                kind: "chat_poster",
                maxPixel: defaultPosterThumbMaxPx,
                jpegQuality: 0.95
            )
        }

        return best
    }

    func downloadFileIfNeeded(
        fileId: Int32,
        priority: Int,
        requestedAvatarFileIds: inout Set<Int32>,
        sendJSON: ([String: Any]) -> Void
    ) {
        if requestedAvatarFileIds.contains(fileId) { return }
        requestedAvatarFileIds.insert(fileId)

        let req: [String: Any] = [
            "@type": "downloadFile",
            "file_id": fileId,
            "priority": priority,
            "offset": 0,
            "limit": 0,
            "synchronous": false
        ]
        sendJSON(req)
    }

    func loadOrMakeThumbNSImage(
        sourcePath: String,
        fileId: Int32?,
        kind: String,
        maxPixel: Int,
        jpegQuality: CGFloat
    ) -> NSImage? {
        guard !sourcePath.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: sourcePath) else { return nil }
        let traceEnabled = ChatPerfTrace.isEnabled(for: nil)
        let avatarThumbStartNs = traceEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if traceEnabled {
                let avatarThumbDurationMs = ChatPerfTrace.elapsedMs(since: avatarThumbStartNs)
                ChatPerfTrace.recordAvatarThumb(chatId: nil, durationMs: avatarThumbDurationMs)
            }
        }

        let memKey = "\(sourcePath)|\(kind)|\(maxPixel)" as NSString
        if let cached = imageMemCache.image(forKey: memKey) {
            return cached
        }

        let fid = fileId ?? stableThumbFallbackFileId(
            sourcePath: sourcePath,
            kind: kind,
            maxPixel: maxPixel
        )

        guard let thumbPath = thumbnailService.ensureThumbnail(
            sourcePath: sourcePath,
            fileId: fid,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: jpegQuality
        ) else {
            if let img = AuroraImageThumb.decodeThumbnailNSImage(sourcePath: sourcePath, maxPixel: maxPixel) {
                imageMemCache.setImage(img, forKey: memKey)
                return img
            }
            return nil
        }

        if let img = NSImage(contentsOfFile: thumbPath) {
            imageMemCache.setImage(img, forKey: memKey)
            return img
        }

        if let img = AuroraImageThumb.decodeThumbnailNSImage(sourcePath: sourcePath, maxPixel: maxPixel) {
            imageMemCache.setImage(img, forKey: memKey)
            return img
        }

        return nil
    }
}
