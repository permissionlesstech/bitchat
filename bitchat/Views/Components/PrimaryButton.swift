//
//  PrimaryButton.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct PrimaryButton: View {
    var title: String
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Capsule().fill(.brandPrimary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Activates \(title)")
    }
}

#Preview {
    PrimaryButton(title: "Next") {}
}
