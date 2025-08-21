//
//  TopCoverHeader.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct TopCoverHeader: View {
    var title: String = "New Circle"
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.orange.opacity(0.35), .pink.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(spacing: 8) {
                EditableCircleAvatar()
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            .padding(.bottom, 8)
        }
    }
}

#Preview {
    TopCoverHeader()
}
