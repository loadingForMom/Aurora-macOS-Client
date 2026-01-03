//
//  MessageBubble.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct MessageBubble: View {
    let msg: TGMessage

    var body: some View {
        HStack {
            if msg.isOutgoing { Spacer(minLength: 40) }

            Text(msg.text)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .foregroundStyle(msg.isOutgoing ? .white : .primary)
                .background(bubbleBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .frame(maxWidth: 560, alignment: msg.isOutgoing ? .trailing : .leading)

            if !msg.isOutgoing { Spacer(minLength: 40) }
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(msg.isOutgoing
                  ? AnyShapeStyle(Color.accentColor.opacity(0.92))
                  : AnyShapeStyle(.thinMaterial))
    }
}
