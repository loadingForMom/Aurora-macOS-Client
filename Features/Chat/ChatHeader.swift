//
//  Untitled.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct ChatHeader: View {
    let title: String
    let isGroup: Bool
    var onToggleInspector: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Left: pencil (new) placeholder
            Button {
                // TODO
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .opacity(0.9)

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                if isGroup {
                    Text("Group")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    // TODO video call
                } label: {
                    Image(systemName: "video")
                }
                .buttonStyle(.plain)
                .opacity(0.9)

                Button(action: onToggleInspector) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .opacity(0.9)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
