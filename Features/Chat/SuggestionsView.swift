//
//  SuggestionsView.swift
//  Aurora
//

import SwiftUI

struct SuggestionsView: View {
    let suggestions: [String]
    var onTapSuggestion: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        onTapSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

private struct SuggestionsViewPreviewContainer: View {
    var body: some View {
        SuggestionsView(suggestions: [
            "Окей, давай так и сделаем.",
            "Да, подходит. Когда удобно созвониться?",
            "Принял, отправлю апдейт к вечеру."
        ]) { _ in }
        .padding(16)
        .frame(width: 520)
    }
}

#Preview("SuggestionsView") {
    SuggestionsViewPreviewContainer()
}
