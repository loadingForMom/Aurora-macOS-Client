//
//  ChatInspectorView.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct ChatInspectorView: View {
    let chat: TGChat

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 72, height: 72)
                    .overlay(Text(String(chat.title.prefix(1)).uppercased()).font(.title2.weight(.semibold)))

                Text(chat.title).font(.headline)
                Text(chat.kind.label).font(.caption).foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 10) {
                Text("Info").font(.subheadline.weight(.semibold))
                Toggle("Send Read Receipts", isOn: .constant(true))
                Toggle("Show in Shared with You", isOn: .constant(true))
            }
            .toggleStyle(.switch)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
