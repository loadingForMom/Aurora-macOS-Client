//
//  BottomScrim.swift
//  Aurora
//
//  Created by Sasha on 1/4/26.
//

import SwiftUI

struct BottomScrim: View {
    var height: CGFloat = 140

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 0.2),
                        .init(color: .black.opacity(0.75), location: 0.65),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }
}
