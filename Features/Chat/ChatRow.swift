//
//  ChatRow.swift
//  Aurora
//

import SwiftUI
import Foundation
import AppKit

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

/// Reusable avatar bubble (used by sidebar + toolbars).
/// Now supports both NSImage and legacy disk path.
struct AvatarCircle: View {
    let title: String
    let image: NSImage?
    let size: CGFloat
    let font: Font

    // Backward compatible initializer (old call sites)
    init(title: String, path: String?, size: CGFloat, font: Font) {
        self.title = title
        self.image = path.flatMap { DiskImageCache.shared.image(path: $0) }
        self.size = size
        self.font = font
    }

    // New initializer (preferred)
    init(title: String, image: NSImage?, size: CGFloat, font: Font) {
        self.title = title
        self.image = image
        self.size = size
        self.font = font
    }

    var body: some View {
        ZStack {
            Circle().fill(.thinMaterial)

            if let img = image {
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
}

struct ChatRow: View {
    @EnvironmentObject private var store: TelegramStore

    let chat: TGChat
    let previewText: String
    let avatarPath: String? // keep (legacy), but we prefer store thumbs

    private var avatarImage: NSImage? {
        // 34pt row avatar; small thumb, fast, cached
        store.chatAvatarNSImage(chatId: chat.id, pointSize: 34, preferHiRes: false)
        ?? avatarPath.flatMap { DiskImageCache.shared.image(path: $0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircle(
                title: chat.title,
                image: avatarImage,
                size: 34,
                font: .caption.weight(.semibold)
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
