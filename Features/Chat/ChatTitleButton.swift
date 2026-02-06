//
//  ChatTitleButton.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import SwiftUI
import AppKit

struct ChatTitleButton: View {
    @EnvironmentObject private var store: TelegramStore

    let title: String
    let chatId: Int64
    let avatarPath: String?

    private var avatarRevision: String {
        let pathPart = avatarPath ?? "nil"
        let version = store.chatAvatarVersionByChatId[chatId] ?? 0
        return "\(pathPart)#\(version)"
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircle(
                title: title,
                identityKey: AvatarCacheKey(
                    kind: .chat,
                    id: chatId,
                    size: 26,
                    scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                    revision: avatarRevision
                ),
                reloadToken: avatarRevision,
                size: 26,
                font: .caption.weight(.semibold),
                imageProvider: {
                    store.chatAvatarNSImage(chatId: chatId, pointSize: 26, preferHiRes: false)
                    ?? avatarPath.flatMap { DiskImageCache.shared.image(path: $0) }
                }
            )
            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
