//
//  ChatTopProfileAvatarView.swift
//  Aurora
//

import SwiftUI
import AppKit

struct ChatTopProfileAvatarView: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    var onTitleTap: () -> Void = {}

    private let avatarSize: CGFloat = 44

    private var avatarPath: String? {
        store.chatAvatarPathByChatId[chat.id]
    }

    private var avatarRevision: String {
        "\(avatarPath ?? "nil")#\(store.chatAvatarVersionByChatId[chat.id] ?? 0)"
    }

    private var avatarIdentity: AvatarCacheKey {
        AvatarCacheKey(
            kind: .chat,
            id: chat.id,
            size: avatarSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            revision: avatarRevision
        )
    }

    var body: some View {
        let fallbackPath = avatarPath

        HStack {
            Spacer(minLength: 0)

            VStack(spacing: -5) {
                AvatarCircle(
                    title: chat.title,
                    identityKey: avatarIdentity,
                    reloadToken: avatarRevision,
                    size: avatarSize,
                    font: .title3.weight(.semibold),
                    imageProvider: { [store, fallbackPath] in
                        if let image = await store.chatAvatarNSImageAsync(
                            chatId: chat.id,
                            pointSize: avatarSize,
                            preferHiRes: true
                        ) {
                            return image
                        }
                        guard let fallbackPath else { return nil }
                        return await DiskImageCache.shared.imageAsync(path: fallbackPath)
                    }
                )
                .background(
                    Circle()
                        
                        .glassEffect(.clear)
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
                .accessibilityLabel("\(chat.title) avatar")
                .zIndex(1)

                Button(action: onTitleTap) {
                    Text(chat.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.2))
                                .glassEffect(.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open inspector")
                    

            }
            .frame(maxWidth: 220)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, -40)
        .padding(.bottom, 2)
        .padding(.horizontal, 12)
        .zIndex(0)
    }
}

#Preview("ChatTopProfileAvatarView") {
    let store = TelegramStore.preview
    let chat = TGChat(
        id: 101,
        title: "Preview Playground",
        kind: .basicGroup,
        order: 9_999_999,
        lastMessagePreview: "Looks great. Let's ship this setup.",
        lastMessageDate: Int(Date().timeIntervalSince1970) - 75
    )

    return ChatTopProfileAvatarView(
        store: store,
        chat: chat
    )
    .frame(width: 420, height: 120)
}
