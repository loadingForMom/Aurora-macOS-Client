//
//  JumpBannerView.swift
//  Aurora
//

import SwiftUI

struct JumpBannerView: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
