//
//  UnreadBadgeView.swift
//  bitchat_iOS
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct UnreadBadgeView: View {
    var count: Int
    var accent: Color = .orange
    
    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(accent))
                .accessibilityLabel("\(count) unread")
        }
    }
}

#Preview {
    UnreadBadgeView(count: 2)
}
