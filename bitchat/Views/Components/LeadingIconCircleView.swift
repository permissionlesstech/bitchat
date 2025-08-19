//
//  LeadingIconCircleView.swift
//  bitchat_iOS
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct LeadingIconCircleView: View {
    var systemName: String
    var bg: Color
    var size: CGFloat = 44
    
    var body: some View {
        ZStack {
            Circle().fill(bg)
            Image(systemName: systemName)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    LeadingIconCircleView(systemName: "megaphone.fill", bg: Color.yellow)
}
