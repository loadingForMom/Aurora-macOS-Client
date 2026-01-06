//
//  ChatRow.swift
//  Aurora
//

import SwiftUI
import Foundation

struct ChatRow: View {
    @EnvironmentObject private var store: TelegramStore
    let chat: TGChat

    var body: some View {
        HStack(spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1)
                Text(sidebarPreview)
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

    private var sidebarPreview: String {
        // If we have the last message locally (e.g. optimistic send), prefer a “truthful” preview.
        if let last = store.messagesByChatId[chat.id]?.last {
            switch last.sendState {
            case .pending:
                return "You: (sending…) \(last.previewText)"
            case .failed:
                return "You: (failed) \(last.previewText)"
            case .sent:
                break
            }
        }

        return chat.lastMessagePreview.isEmpty ? chat.kind.label : chat.lastMessagePreview
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)

            if let img = store.chatAvatarNSImage(chatId: chat.id) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Text(initials(from: chat.title))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34, height: 34)
        .overlay(
            Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
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

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
