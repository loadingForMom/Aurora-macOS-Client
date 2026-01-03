//
//  MessagesPane.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct MessagesPane: View {
    @ObservedObject var store: TelegramStore
    let chat: TGChat

    var body: some View {
        let messages = store.messagesByChatId[chat.id] ?? []
        let groups = groupMessages(messages)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { g in
                        MessageGroupView(store: store, chat: chat, group: g)
                            .id(g.id)
                    }

                    if store.showLogs {
                        Divider().padding(.vertical, 10)
                        Text(store.logs.joined(separator: "\n\n"))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: messages.last?.id) { _, lastId in
                guard let lastId else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func groupMessages(_ msgs: [TGMessage]) -> [MessageGroup] {
        guard !msgs.isEmpty else { return [] }
        let gap: Int = 5 * 60

        var out: [MessageGroup] = []
        var bucket: [TGMessage] = [msgs[0]]
        var curSender: Int64? = msgs[0].senderUserId
        var curOutgoing = msgs[0].isOutgoing

        func flush() {
            guard let first = bucket.first else { return }
            out.append(MessageGroup(
                id: "g:\(first.chatId):\(first.id)",
                isOutgoing: curOutgoing,
                senderUserId: curSender,
                messages: bucket
            ))
        }

        for m in msgs.dropFirst() {
            let sameSender = (m.senderUserId == curSender)
            let sameDir = (m.isOutgoing == curOutgoing)
            let close = abs(m.date - (bucket.last?.date ?? m.date)) <= gap

            if sameSender && sameDir && close {
                bucket.append(m)
            } else {
                flush()
                bucket = [m]
                curSender = m.senderUserId
                curOutgoing = m.isOutgoing
            }
        }

        flush()
        return out
    }
}

struct MessageGroup: Identifiable, Hashable {
    let id: String
    let isOutgoing: Bool
    let senderUserId: Int64?
    let messages: [TGMessage]
}
