//
//  Untitled.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI
import AppKit

struct ChatHeader: View {
    let title: String
    let isGroup: Bool
    let avatar: NSImage?
    var onToggleInspector: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                // TODO new chat
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onToggleInspector) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(.thinMaterial)

                        if let avatar {
                            Image(nsImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .clipShape(Circle())
                        } else {
                            Text(initials(from: title))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))

                    VStack(spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)

                        if isGroup {
                            Text("Group")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                // TODO video call
            } label: {
                Image(systemName: "video")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func initials(from title: String) -> String {
        let parts = title
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }

        if parts.isEmpty, let first = title.first {
            return String(first).uppercased()
        }
        return parts.joined()
    }
}
