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
        let avatarSize: CGFloat = 26
        let avatarOverlap: CGFloat = 3
        let avatarLowering: CGFloat = 8
        let avatarLift = max(0, avatarSize - avatarOverlap - avatarLowering)

        Text(title)
            .font(.headline)
            .lineLimit(1)
            .overlay(alignment: .top) {
                AvatarCircle(
                    title: title,
                    identityKey: AvatarCacheKey(
                        kind: .chat,
                        id: chatId,
                        size: avatarSize,
                        scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                        revision: avatarRevision
                    ),
                    reloadToken: avatarRevision,
                    size: avatarSize,
                    font: .caption.weight(.semibold),
                    imageProvider: {
                        if let image = await store.chatAvatarNSImageAsync(
                            chatId: chatId,
                            pointSize: avatarSize,
                            preferHiRes: false
                        ) {
                            return image
                        }
                        guard let avatarPath else { return nil }
                        return await DiskImageCache.shared.imageAsync(path: avatarPath)
                    }
                )
                .offset(y: -avatarLift)
            }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

private struct ChatTitleButtonPreviewContainer: View {
    @StateObject private var store = TelegramStore.preview

    var body: some View {
        ChatTitleButton(
            title: "Preview Playground",
            chatId: 101,
            avatarPath: nil
        )
        .environmentObject(store)
        .frame(width: 260, height: 48)
        .padding(.horizontal, 8)
    }
}

#Preview("ChatTitleButton") {
    ChatTitleButtonPreviewContainer()
}
