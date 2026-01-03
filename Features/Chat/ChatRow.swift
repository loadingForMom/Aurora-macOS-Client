import SwiftUI
import Foundation

struct ChatRow: View {
    let chat: TGChat

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.thinMaterial)
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(chat.title.prefix(1)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1)
                Text(chat.lastMessagePreview.isEmpty ? chat.kind.label : chat.lastMessagePreview)
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

    private func relativeTime(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
