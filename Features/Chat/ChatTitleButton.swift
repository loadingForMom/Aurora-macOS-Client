//
//  ChatTitleButton.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import SwiftUI

struct ChatTitleButton: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            avatar

            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    // Пока без настоящих фоток: делаем iMessage-style плейсхолдер.
    // Фото подтянем позже через TDLib (getUserProfilePhotos + downloadFile).
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
            Text(initials(from: title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 26, height: 26)
    }

    private func initials(from name: String) -> String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }

        if parts.isEmpty {
            return "?"
        }
        return parts.joined()
    }
}
