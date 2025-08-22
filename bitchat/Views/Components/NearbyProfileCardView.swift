//
//  NearbyProfileCardView.swift
//  bitchat_iOS
//
//  Created by Saputra on 19/08/25.
//

import SwiftUI

struct NearbyProfileCardView: View {
    let profile: NearbyProfile
    
    var size: CGFloat = 72
    var ringWidth: CGFloat = 4
    var action: (() -> Void)? = nil
    
    var body: some View {
        content
            .frame(width: size + 24)
    }
    
    @ViewBuilder
    private var content: some View {
        let avatar = avatarView
        let labels = labelsView
        
        if let action {
            Button(action: action) {
                VStack(spacing: 8) {
                    avatar
                    labels
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(profile.name)")
            .accessibilityHint("Opens \(profile.name)'s profile")
            .accessibilityAddTraits(.isButton)
        } else {
            VStack(spacing: 8) {
                avatar
                labels
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(profile.name)")
        }
    }
    
    private var avatarView: some View {
        ZStack {
            Circle()
                .strokeBorder(.orange, lineWidth: ringWidth)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 2)
            
            if let img = profile.image {
                img
                    .resizable()
                    .scaledToFill()
                    .frame(width: size - ringWidth * 2, height: size - ringWidth * 2)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Text(profile.initials)
                            .font(.system(size: size * 0.35, weight: .semibold))
                            .foregroundStyle(.primary)
                    )
                    .frame(width: size - ringWidth * 2, height: size - ringWidth * 2)
                    .accessibilityHidden(true)
            }
        }
    }
    
    private var labelsView: some View {
        VStack(spacing: 2) {
            Text(profile.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private let dummyProfiles: [NearbyProfile] = [
    .init(name: "Saputra", team: "Team 1", image: Image("picture1"), initials: "SU"),
    .init(name: "Ayu",     team: "Team 2", image: Image("picture2"), initials: "AY"),
    .init(name: "Putri",   team: "Team 3", image: Image("picture3"), initials: "PT"),
    .init(name: "Agus",    team: "Team 4", image: nil,               initials: "AG"),
]


#Preview("NearbyProfileCard - single") {
    NearbyProfileCardView(profile: dummyProfiles[0]) { print("Tapped") }
        .padding()
        .background(Color.white)
}

#Preview("NearbyProfileCard - horizontal list") {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
            ForEach(dummyProfiles) { p in
                NearbyProfileCardView(profile: p) { print("\(p.name) tapped") }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
    .background(Color.white)
}
