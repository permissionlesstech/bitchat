//
//  CircleIconButtonView.swift
//  bitchat_iOS
//
//  Created by Saputra on 19/08/25.
//

import SwiftUI

struct CircleIconButtonView: View {
    var systemIcon: String = "plus"
    var diameter: CGFloat = 44
    var accessibilityLabel: String? = "Creates a new group"
    var accessibilityText: String? = "Add"
    var action: () -> Void = {}
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemIcon)
                .font(.system(size: diameter * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.orange))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText ?? "Add")
        .accessibilityHint(accessibilityLabel ?? "Creates a new item.")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    NavigationStack {
        VStack {
        }
        .padding()
        
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CircleIconButtonView()
            }
        }
    }
}
