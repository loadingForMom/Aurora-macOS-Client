//
//  ChatHeader.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit

struct ChatHeader: View {
    @EnvironmentObject private var store: TelegramStore

    let title: String
    let isGroup: Bool
    let chatId: Int64

    /// NOTE:
    /// Это поле оставлено строкой для совместимости с твоими вызовами.
    /// Идея оптимизации: сюда лучше передавать уже thumb-path (не оригинал TDLib),
    /// но если где-то передаётся оригинал — он всё равно будет выглядеть, просто может быть тяжелее.
    let avatarPath: String?

    var onToggleInspector: () -> Void

    private var avatarRevision: String {
        let pathPart = avatarPath ?? "nil"
        let version = store.chatAvatarVersionByChatId[chatId] ?? 0
        return "\(pathPart)#\(version)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                // TODO new chat
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onToggleInspector) {
                let avatarSize: CGFloat = 28
                let avatarOverlap: CGFloat = 3
                let avatarLowering: CGFloat = 8
                let avatarLift = max(0, avatarSize - avatarOverlap - avatarLowering)

                VStack(spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)

                    if isGroup {
                        Text("Group")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                        font: .system(size: 11, weight: .semibold, design: .rounded),
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
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .offset(y: -avatarLift)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                // TODO video call
            } label: {
                Image(systemName: "video")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
