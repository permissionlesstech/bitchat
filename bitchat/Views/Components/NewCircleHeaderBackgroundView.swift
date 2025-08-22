//
//  NewCircleHeaderBackgroundView.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct NewCircleHeaderBackgroundView: View {
    var imageName: String = "bubble"
    
    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.clear, lineWidth: 0)
            )
            .accessibilityHidden(true)
    }
}

#Preview {
    NewCircleHeaderBackgroundView()
        .padding()
        .background(Color(.background))
}
