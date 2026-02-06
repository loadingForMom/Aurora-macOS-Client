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

    var cacheKey: NSString {
        "\(kind.rawValue):\(id):\(size):\(scale)" as NSString
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
    let imageProvider: (() -> NSImage?)?
    let size: CGFloat
    let font: Font
    @State private var loadedImage: NSImage? = nil

    init(title: String, path: String?, size: CGFloat, font: Font) {
        self.title = title
        self.image = path.flatMap { DiskImageCache.shared.image(path: $0) }
        self.identityKey = nil
        self.imageProvider = nil
        self.size = size
        self.font = font
    }

    init(title: String, image: NSImage?, size: CGFloat, font: Font) {
        self.title = title
        self.image = image
        self.identityKey = nil
        self.imageProvider = nil
        self.size = size
        self.font = font
    }

    init(title: String, identityKey: AvatarCacheKey, size: CGFloat, font: Font, imageProvider: @escaping () -> NSImage?) {
        self.title = title
        self.image = nil
        self.identityKey = identityKey
        self.imageProvider = imageProvider
        self.size = size
        self.font = font
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
        .task(id: identityKey) {
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
        let image = await Task.detached(priority: .userInitiated) {
            imageProvider()
        }.value

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
    @EnvironmentObject private var store: TelegramStore

    let chat: TGChat
    let previewText: String
    let avatarPath: String? // keep (legacy), but we prefer store thumbs

    private var avatarIdentity: AvatarCacheKey {
        AvatarCacheKey(kind: .chat, id: chat.id, size: 34, scale: AvatarScale.current)
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircle(
                title: chat.title,
                identityKey: avatarIdentity,
                size: 34,
                font: .caption.weight(.semibold),
                imageProvider: {
                    store.chatAvatarNSImage(chatId: chat.id, pointSize: 34, preferHiRes: false)
                    ?? avatarPath.flatMap { DiskImageCache.shared.image(path: $0) }
                }
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
