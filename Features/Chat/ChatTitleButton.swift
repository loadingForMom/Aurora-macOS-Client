//
//  ChatTitleButton.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import SwiftUI

struct ChatTitleButton: View {
    let title: String
    let avatarPath: String?

    var body: some View {
        HStack(spacing: 10) {
            AvatarCircle(
                title: title,
                path: avatarPath,
                size: 26,
                font: .caption.weight(.semibold)
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
