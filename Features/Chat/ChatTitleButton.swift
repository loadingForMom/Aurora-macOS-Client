//
//  ChatTitleButton.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import SwiftUI
import AppKit

struct ChatTitleButton: View {
    let title: String
    let chatId: Int64
    let avatarPath: String?

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircle(
                title: title,
                identityKey: AvatarCacheKey(
                    kind: .chat,
                    id: chatId,
                    size: 26,
                    scale: NSScreen.main?.backingScaleFactor ?? 2.0
                ),
                size: 26,
                font: .caption.weight(.semibold),
                imageProvider: {
                    avatarPath.flatMap { DiskImageCache.shared.image(path: $0) }
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
