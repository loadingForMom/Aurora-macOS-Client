//
//  ChatRow.swift
//  Aurora
//

import SwiftUI
import Foundation
import AppKit
import OSLog

/// Shared disk image cache for avatars (prevents repeated NSImage(contentsOfFile:) thrash).
final class DiskImageCache {
    static let shared = DiskImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let decodeQueue = DispatchQueue(
        label: "com.aurora.app.avatar.disk.decode",
        qos: .utility,
        attributes: .concurrent
    )

    private init() {
        cache.countLimit = 512
    }

    func image(path: String) -> NSImage? {
        let key = path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard FileManager.default.fileExists(atPath: path),
              let img = NSImage(contentsOfFile: path)
        else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    func imageAsync(path: String) async -> NSImage? {
        let cacheKey = path
        if let hit = cache.object(forKey: cacheKey as NSString) { return hit }

        return await withCheckedContinuation { continuation in
            decodeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let key = cacheKey as NSString
                if let hit = self.cache.object(forKey: key) {
                    continuation.resume(returning: hit)
                    return
                }
                guard FileManager.default.fileExists(atPath: cacheKey),
                      let img = NSImage(contentsOfFile: cacheKey)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                self.cache.setObject(img, forKey: key)
                continuation.resume(returning: img)
            }
        }
    }
}

struct AvatarCacheKey: Hashable {
    enum Kind: String, Hashable {
        case chat
        case user
    }

    let kind: Kind
    let id: Int64
    let size: CGFloat
    let scale: CGFloat
    let revision: String

    var cacheKey: NSString {
        "\(kind.rawValue):\(id):\(size):\(scale):\(revision)" as NSString
    }
}

private let avatarLog = Logger(subsystem: "com.aurora.app", category: "avatar")

final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 512
    }

    func image(for key: AvatarCacheKey) -> NSImage? {
        cache.object(forKey: key.cacheKey)
    }

    func set(_ image: NSImage, for key: AvatarCacheKey) {
        cache.setObject(image, forKey: key.cacheKey)
    }
}

private enum AvatarScale {
    static var current: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }
}

/// Reusable avatar bubble (used by sidebar + toolbars).
/// Now supports both NSImage and legacy disk path.
struct AvatarCircle: View {
    let title: String
    let image: NSImage?
    let identityKey: AvatarCacheKey?
    let reloadToken: String?
    let imageProvider: (() async -> NSImage?)?
    let size: CGFloat
    let font: Font
    @State private var loadedImage: NSImage? = nil

    init(title: String, path: String?, size: CGFloat, font: Font) {
        self.title = title
        self.image = path.flatMap { DiskImageCache.shared.image(path: $0) }
        self.identityKey = nil
        self.reloadToken = path
        self.imageProvider = nil
        self.size = size
        self.font = font
    }

    init(title: String, image: NSImage?, size: CGFloat, font: Font) {
        self.title = title
        self.image = image
        self.identityKey = nil
        self.reloadToken = nil
        self.imageProvider = nil
        self.size = size
        self.font = font
    }

    init(
        title: String,
        identityKey: AvatarCacheKey,
        reloadToken: String? = nil,
        size: CGFloat,
        font: Font,
        imageProvider: @escaping () async -> NSImage?
    ) {
        self.title = title
        self.image = nil
        self.identityKey = identityKey
        self.reloadToken = reloadToken
        self.imageProvider = imageProvider
        self.size = size
        self.font = font
    }

    private var loadTaskId: String {
        if let identityKey {
            return "\(identityKey.cacheKey)|\(reloadToken ?? "nil")"
        }
        return "legacy|\(reloadToken ?? "nil")|\(title)"
    }

    var body: some View {
        ZStack {
            Circle().fill(.thinMaterial)

            if let img = loadedImage ?? image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(initials(from: title))
                    .font(font)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: identityKey) { _, _ in
            loadedImage = nil
        }
        .onChange(of: reloadToken) { _, _ in
            loadedImage = nil
        }
        .task(id: loadTaskId) {
            await loadAvatarImage()
        }
    }

    private func initials(from title: String) -> String {
        let parts = title
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }

        if parts.isEmpty {
            return title.first.map { String($0).uppercased() } ?? "?"
        }
        return parts.joined()
    }

    @MainActor
    private func loadAvatarImage() async {
        guard let identityKey, let imageProvider else {
            loadedImage = nil
            return
        }

        loadedImage = nil

        if let cached = AvatarImageCache.shared.image(for: identityKey) {
            loadedImage = cached
            return
        }

        let requestKey = identityKey
        let image = await imageProvider()

        guard !Task.isCancelled else { return }
        guard self.identityKey == requestKey else {
#if DEBUG
            assertionFailure("Avatar identity mismatch: expected \(String(describing: self.identityKey)) got \(requestKey)")
            avatarLog.debug("discarded image for \(String(describing: requestKey), privacy: .public)")
#endif
            return
        }

        if let image {
            AvatarImageCache.shared.set(image, for: requestKey)
        }
        loadedImage = image
    }
}

struct ChatRow: View {
    let chat: TGChat
    let previewText: String
    let avatarPath: String?
    let avatarRevision: String
    let avatarImageProvider: () async -> NSImage?

    private var avatarIdentity: AvatarCacheKey {
        AvatarCacheKey(
            kind: .chat,
            id: chat.id,
            size: 34,
            scale: AvatarScale.current,
            revision: avatarRevision
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircle(
                title: chat.title,
                identityKey: avatarIdentity,
                reloadToken: avatarRevision,
                size: 34,
                font: .caption.weight(.semibold),
                imageProvider: avatarImageProvider
            )
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1)
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if chat.lastMessageDate != 0 {
                Text(relativeTime(chat.lastMessageDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ChatRowPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview

    private let chat = TGChat(
        id: 101,
        title: "Preview Playground",
        kind: .basicGroup,
        order: 9_999_999,
        lastMessagePreview: "Looks great. Let's ship this setup.",
        lastMessageDate: Int(Date().timeIntervalSince1970) - 75
    )

    var body: some View {
        let avatarPath = store.chatAvatarPathByChatId[chat.id]
        let avatarRevision = "\(avatarPath ?? "nil")#\(store.chatAvatarVersionByChatId[chat.id] ?? 0)"
        List {
            ChatRow(
                chat: chat,
                previewText: chat.lastMessagePreview,
                avatarPath: avatarPath,
                avatarRevision: avatarRevision,
                avatarImageProvider: { [store, avatarPath] in
                    if let image = await store.chatAvatarNSImageAsync(
                        chatId: chat.id,
                        pointSize: 34,
                        preferHiRes: false
                    ) {
                        return image
                    }
                    guard let avatarPath else { return nil }
                    return await DiskImageCache.shared.imageAsync(path: avatarPath)
                }
            )
        }
        .listStyle(.sidebar)
        .frame(width: 360, height: 110)
    }
}

#Preview("ChatRow") {
    ChatRowPreviewContainer()
}
