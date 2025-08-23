//
//  NearbyEmptyView.swift
//  bitchat_iOS
//
//  Created by Saputra on 19/08/25.
//

import SwiftUI

struct NearbyEmptyView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("radio")
                .scaledToFill()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Seems like there are no other devices nearby you right now.")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No nearby devices found.")
    }
}

#Preview {
    NearbyEmptyView()
}
