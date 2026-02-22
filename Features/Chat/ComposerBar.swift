//
//  ComposerBar.swift
//  Aurora
//
//  Created by Sasha on 1/3/26.
//

import SwiftUI

struct GlassComposerBar: View {
    @Binding var text: String
    var onPlus: () -> Void = {}
    var onSend: () -> Void = {}
    
    @State private var plusBounceTrigger = 0

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
           HStack(spacing: 10) {
               Button {
                   onPlus()
                   plusBounceTrigger += 1
               } label: {
                   Image(systemName: "document.badge.plus")
                       .symbolEffect(.bounce.up.byLayer,
                                     options: .nonRepeating,
                                     value: plusBounceTrigger)
                       .symbolRenderingMode(.palette)
                             .foregroundStyle(
                                 .green,
                                 .black
                             )
                       .frame(width: 34, height: 34)
                       .contentShape(Circle())
               }
               .buttonStyle(.plain)
               .glassEffect(in: Circle())

            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .glassEffect(in: Capsule(style: .continuous))

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(in: Circle())
            .disabled(trimmedText.isEmpty)
            .opacity(trimmedText.isEmpty ? 0.45 : 1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GlassComposerBarPreviewContainer: View {
    @State private var text = "Preview message"

    var body: some View {
        GlassComposerBar(text: $text)
            .padding(16)
            .frame(width: 540)
    }
}

#Preview("GlassComposerBar") {
    GlassComposerBarPreviewContainer()
}
