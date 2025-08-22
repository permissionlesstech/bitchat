//
//  NearYouSection.swift
//  bitchat_iOS
//
//  Created by Saputra on 19/08/25.
//

import SwiftUI

struct NearYouSectionView: View {
    let profiles: [NearbyProfile]
    var onTapProfile: ((NearbyProfile) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Near You")
                .padding(.horizontal)
            
            if profiles.isEmpty {
                NearbyEmptyView()
                    .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(profiles) { p in
                            NearbyProfileCardView(profile: p) {
                                onTapProfile?(p)
                            }
                        }
                    }
                    
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("Nearby people list, horizontal")
            }
        }
    }
}

#Preview("NearYouSection – has data") {
    NearYouSectionView(
        profiles: [
            .init(name: "Saputra", team: "Team 1", image: Image("picture1"), initials: "SU"),
            .init(name: "Ayu",     team: "Team 2", image: Image("picture2"), initials: "AY"),
            .init(name: "Putri",   team: "Team 3", image: Image("picture3"), initials: "PT"),
            .init(name: "Agus",    team: "Team 4", image: Image("picture4"), initials: "AG")
        ],
        onTapProfile: { _ in print("Tapped") }
    )
    .background(Color.white)
}

#Preview("NearYouSection – empty") {
    NearYouSectionView(profiles: [])
        .background(Color.white)
}
