//
//  TopLoaderView.swift
//  Aurora
//

import SwiftUI

struct TopLoaderView: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
