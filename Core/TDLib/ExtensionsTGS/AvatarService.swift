//  AvatarService.swift
//  Aurora
//

import Foundation
import AppKit

final class AvatarService {
    struct ChatAvatarMeta {
        var smallFileId: Int32?
        var bigFileId: Int32?
        var smallPath: String?
        var bigPath: String?
    }

    private let imageMemCache = NSCache<NSString, NSImage>()
    private let thumbsDirURL: URL

    private let defaultListThumbMaxPx: Int = 128
    private let defaultProfileThumbMaxPx: Int = 128
    private let defaultInspectorThumbMaxPx: Int = 1024
    private let defaultPosterThumbMaxPx: Int = 2048

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Aurora/thumbs", isDirectory: true)
        thumbsDirURL = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        imageMemCache.countLimit = 256
    }

    func clearMemoryCache() {
        imageMemCache.removeAllObjects()
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
        let cap = maxClamp ?? (preferHiRes ? defaultInspectorThumbMaxPx : defaultListThumbMaxPx)
        let maxPx = maxPixel(forPointSize: pointSize, clampTo: cap)

        let meta = chatAvatarMetaByChatId[chatId]
        let src: String? = {
            if preferHiRes {
                if let p = meta?.bigPath, !p.isEmpty { return p }
                if let p = meta?.smallPath, !p.isEmpty { return p }
                return chatAvatarPathByChatId[chatId]
            } else {
                if let p = meta?.smallPath, !p.isEmpty { return p }
                if let p = meta?.bigPath, !p.isEmpty { return p }
                return chatAvatarPathByChatId[chatId]
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
        }
    }

    func applyChatAvatarFileUpdate(
        chatId: Int64,
        fileId: Int32,
        path: String,
        chatAvatarMetaByChatId: inout [Int64: ChatAvatarMeta],
        chatAvatarPathByChatId: inout [Int64: String]
    ) {
        var meta = chatAvatarMetaByChatId[chatId] ?? ChatAvatarMeta()

        if meta.smallFileId == fileId {
            meta.smallPath = path
        } else if meta.bigFileId == fileId {
            meta.bigPath = path
        } else {
            if meta.smallPath == nil { meta.smallPath = path }
            else if meta.bigPath == nil { meta.bigPath = path }
        }

        chatAvatarMetaByChatId[chatId] = meta

        let best = (meta.smallPath?.isEmpty == false ? meta.smallPath : meta.bigPath)
        if let best, !best.isEmpty {
            chatAvatarPathByChatId[chatId] = best
        }

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

        let memKey = "\(sourcePath)|\(kind)|\(maxPixel)" as NSString
        if let cached = imageMemCache.object(forKey: memKey) {
            return cached
        }

        let fid = fileId ?? stableThumbFallbackFileId(
            sourcePath: sourcePath,
            kind: kind,
            maxPixel: maxPixel
        )

        guard let thumbPath = AuroraImageThumb.ensureThumbnail(
            sourcePath: sourcePath,
            cacheDirURL: thumbsDirURL,
            fileId: fid,
            kind: kind,
            maxPixel: maxPixel,
            jpegQuality: jpegQuality
        ) else {
            if let img = AuroraImageThumb.decodeThumbnailNSImage(sourcePath: sourcePath, maxPixel: maxPixel) {
                imageMemCache.setObject(img, forKey: memKey)
                return img
            }
            return nil
        }

        if let img = NSImage(contentsOfFile: thumbPath) {
            imageMemCache.setObject(img, forKey: memKey)
            return img
        }

        if let img = AuroraImageThumb.decodeThumbnailNSImage(sourcePath: sourcePath, maxPixel: maxPixel) {
            imageMemCache.setObject(img, forKey: memKey)
            return img
        }

        return nil
    }
}
