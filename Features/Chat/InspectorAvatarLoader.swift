//
//  InspectorAvatarLoader.swift
//  Aurora
//

import AppKit
import Combine
import Foundation

struct InspectorAvatarSnapshot: Sendable {
    let sourcePath: String
    let fileId: Int32?
    let kind: String
    let maxPixel: Int
    let jpegQuality: CGFloat
}

@MainActor
final class InspectorAvatarLoader: ObservableObject {
    @Published private(set) var posterImage: NSImage?
    @Published private(set) var chromeAvatarImage: NSImage?

    private let decodeQueue = DispatchQueue(
        label: "com.aurora.app.inspector.avatar.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let cache = NSCache<NSString, NSImage>()

    private var currentChatId: Int64 = 0
    private var posterRequestKey: String?
    private var chromeRequestKey: String?
    private var prefetchRequestKey: String?
    private var posterGeneration: Int = 0
    private var chromeGeneration: Int = 0

    init() {
        cache.countLimit = 24
    }

    func prefetchHiResIfNeeded(chatId: Int64, avatarVersion: Int, store: TelegramStore) {
        let key = "\(chatId):\(avatarVersion)"
        guard prefetchRequestKey != key else { return }
        prefetchRequestKey = key
        store.prefetchChatAvatarHiResIfNeeded(chatId: chatId)
    }

    func update(
        chatId: Int64,
        avatarVersion: Int,
        posterWidth: CGFloat,
        heroHeight: CGFloat,
        pinnedAvatarSize: CGFloat,
        store: TelegramStore
    ) {
        if currentChatId != chatId {
            resetState(for: chatId)
        }

        let posterPointSize = max(posterWidth, heroHeight)
        let posterSnapshot = store.inspectorAvatarSnapshot(
            chatId: chatId,
            pointSize: posterPointSize,
            preferHiRes: true,
            maxClamp: 3072,
            kindOverride: "chat_poster"
        )
        scheduleLoad(
            target: .poster,
            snapshot: posterSnapshot,
            requestKey: makeRequestKey(
                chatId: chatId,
                avatarVersion: avatarVersion,
                snapshot: posterSnapshot,
                pointSize: posterPointSize
            )
        )

        let chromeSnapshot = store.inspectorAvatarSnapshot(
            chatId: chatId,
            pointSize: pinnedAvatarSize,
            preferHiRes: true,
            maxClamp: nil,
            kindOverride: nil
        )
        scheduleLoad(
            target: .chrome,
            snapshot: chromeSnapshot,
            requestKey: makeRequestKey(
                chatId: chatId,
                avatarVersion: avatarVersion,
                snapshot: chromeSnapshot,
                pointSize: pinnedAvatarSize
            )
        )
    }

    func clear() {
        posterRequestKey = nil
        chromeRequestKey = nil
        prefetchRequestKey = nil
        posterGeneration &+= 1
        chromeGeneration &+= 1
        posterImage = nil
        chromeAvatarImage = nil
    }

    private enum Target {
        case poster
        case chrome
    }

    private func resetState(for chatId: Int64) {
        currentChatId = chatId
        posterRequestKey = nil
        chromeRequestKey = nil
        prefetchRequestKey = nil
        posterGeneration = 0
        chromeGeneration = 0
        posterImage = nil
        chromeAvatarImage = nil
    }

    private func makeRequestKey(
        chatId: Int64,
        avatarVersion: Int,
        snapshot: InspectorAvatarSnapshot?,
        pointSize: CGFloat
    ) -> String {
        guard let snapshot else {
            return "\(chatId):\(avatarVersion):missing"
        }
        return "\(chatId):\(avatarVersion):\(snapshot.sourcePath):\(snapshot.fileId ?? 0):\(snapshot.kind):\(snapshot.maxPixel):\(Int(pointSize.rounded()))"
    }

    private func scheduleLoad(target: Target, snapshot: InspectorAvatarSnapshot?, requestKey: String) {
        guard let snapshot else {
            apply(nil, for: target, requestKey: requestKey)
            return
        }

        switch target {
        case .poster:
            if posterRequestKey == requestKey { return }
            posterRequestKey = requestKey
            posterGeneration &+= 1
            let generation = posterGeneration
            if let cached = cache.object(forKey: requestKey as NSString) {
                posterImage = cached
                return
            }
            decodeQueue.async { [snapshot, requestKey] in
                let image = Self.decodeSnapshot(snapshot)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.posterRequestKey == requestKey else { return }
                    guard self.posterGeneration == generation else { return }
                    if let image {
                        self.cache.setObject(image, forKey: requestKey as NSString)
                    }
                    self.posterImage = image
                }
            }

        case .chrome:
            if chromeRequestKey == requestKey { return }
            chromeRequestKey = requestKey
            chromeGeneration &+= 1
            let generation = chromeGeneration
            if let cached = cache.object(forKey: requestKey as NSString) {
                chromeAvatarImage = cached
                return
            }
            decodeQueue.async { [snapshot, requestKey] in
                let image = Self.decodeSnapshot(snapshot)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.chromeRequestKey == requestKey else { return }
                    guard self.chromeGeneration == generation else { return }
                    if let image {
                        self.cache.setObject(image, forKey: requestKey as NSString)
                    }
                    self.chromeAvatarImage = image
                }
            }
        }
    }

    nonisolated private static func decodeSnapshot(_ snapshot: InspectorAvatarSnapshot) -> NSImage? {
        // Decode off-main to avoid scroll hitch from sync thumbnail generation.
        AvatarService().loadOrMakeThumbNSImage(
            sourcePath: snapshot.sourcePath,
            fileId: snapshot.fileId,
            kind: snapshot.kind,
            maxPixel: snapshot.maxPixel,
            jpegQuality: snapshot.jpegQuality
        )
    }

    private func apply(_ image: NSImage?, for target: Target, requestKey: String) {
        switch target {
        case .poster:
            posterRequestKey = requestKey
            posterGeneration &+= 1
            posterImage = image
        case .chrome:
            chromeRequestKey = requestKey
            chromeGeneration &+= 1
            chromeAvatarImage = image
        }
    }
}

extension TelegramStore {
    @MainActor
    func inspectorAvatarSnapshot(
        chatId: Int64,
        pointSize: CGFloat,
        preferHiRes: Bool,
        maxClamp: Int?,
        kindOverride: String?
    ) -> InspectorAvatarSnapshot? {
        let cap = maxClamp ?? (preferHiRes ? 1024 : 128)
        let maxPx = maxPixel(forPointSize: pointSize, clampTo: cap)
        let meta = chatAvatarMetaByChatId[chatId]

        let sourcePath: String? = {
            if preferHiRes {
                if let path = meta?.bigPath, !path.isEmpty { return path }
                if let path = meta?.smallPath, !path.isEmpty { return path }
                return chatAvatarPathByChatId[chatId]
            }
            if let path = meta?.smallPath, !path.isEmpty { return path }
            if let path = meta?.bigPath, !path.isEmpty { return path }
            return chatAvatarPathByChatId[chatId]
        }()

        guard let sourcePath, !sourcePath.isEmpty else { return nil }

        let fileId: Int32? = {
            if preferHiRes {
                return meta?.bigFileId ?? meta?.smallFileId
            }
            return meta?.smallFileId ?? meta?.bigFileId
        }()

        let kind = kindOverride ?? (preferHiRes ? "chat_big" : "chat_small")
        let quality: CGFloat = preferHiRes ? 0.92 : 0.88

        return InspectorAvatarSnapshot(
            sourcePath: sourcePath,
            fileId: fileId,
            kind: kind,
            maxPixel: maxPx,
            jpegQuality: quality
        )
    }
}
