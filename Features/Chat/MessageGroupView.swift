//
//  MessageBubble.swift
//  Aurora
//
//  iMessage-ish bubble styling using system materials.
//

import SwiftUI

struct MessageGroupView: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat
    let group: MessageGroup

    var body: some View {
        VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 6) {
            if chat.kind.isGroup && !group.isOutgoing {
                let name = store.userDisplayName(group.senderUserId)
                if !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }

            VStack(alignment: group.isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(group.messages) { msg in
                    MessageBubble(msg: msg)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: group.isOutgoing ? .trailing : .leading)
        .padding(.vertical, 2)
    }
}
