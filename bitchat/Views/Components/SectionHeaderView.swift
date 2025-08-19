//
//  SectionHeader.swift
//  bitchat_iOS
//
//  Created by Saputra on 19/08/25.
//

import SwiftUI

struct SectionHeaderView: View {
    let title: String
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        SectionHeaderView(title: "Near You")
        SectionHeaderView(
                    title: "Chats")
    }
    .padding(.horizontal, 20)
}
