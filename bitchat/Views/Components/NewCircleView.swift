//
//  NewCircleView.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct NewCircleView: View {
    @State private var circleName: String = "Circle Name"
    @State private var showSheet = true
    
    let nearbyProfiles: [NearbyProfile]
    
    let onTapProfile: ((NearbyProfile) -> Void)?
    
    var body: some View {
        ZStack(alignment: .top){
            Color.background
            VStack {
                Image("bubble")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 400, height: 350)
                    .offset(x:40)
            }
            VStack(spacing: 8) {
                EditableCircleAvatar(onEdit: { showSheet = true })
                Text(circleName)
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 120)
        }
        .ignoresSafeArea(.all)
        .navigationTitle("New Circle")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSheet) {
            if #available(iOS 16.4, *) {
                EditCircleSheet(circleName: $circleName, nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
                    .presentationDetents([.height(540)])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
                    .presentationBackgroundInteraction(.enabled)
            } else {
                EditCircleSheet(circleName: $circleName, nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
                    .presentationDetents([.height(540)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

struct EditCircleSheet: View {
    @Binding var circleName: String
    let nearbyProfiles: [NearbyProfile]
    let onTapProfile: ((NearbyProfile) -> Void)?
    
    private let cardSize: CGFloat = 72
        private let spacing: CGFloat = 16
    
    var body: some View {
        VStack {
            SectionHeaderView(title: "Nearby")
            if nearbyProfiles.isEmpty {
                NearbyEmptyView()
            }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize), spacing: spacing, alignment: .top)], alignment: .leading, spacing: spacing) {
                    ForEach(nearbyProfiles) { p in
                        NearbyProfileCardView(profile: p) {
                            onTapProfile?(p)
                        }
                        .frame(width: cardSize + 24, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            
            if !nearbyProfiles.isEmpty {
                HStack {
                    Spacer()
                    PrimaryButton(title: "Next", action: {})
                }
                .padding()
            }
        }
        .padding(.horizontal)
        .padding(.top, 36)
    }
}

#Preview("With Data") {
    let nearbyProfiles: [NearbyProfile] = [
        .init(name: "Saputra", team: "Team 1", image: Image("picture1"), initials: "SU"),
        .init(name: "Ayu", team: "Team 2", image: Image("picture2"), initials: "AY"),
        .init(name: "Putri", team: "Team 3", image: Image("picture3"), initials: "PT"),
        .init(name: "Putra", team: "Team 4", image: Image("picture4"), initials: "PT"),
        .init(name: "Bam", team: "Team 5", image: Image("picture1"), initials: "BA")
    ]
    
    let onTapProfile: ((NearbyProfile) -> Void)? = { _ in print("Tapped") }
    
    NavigationStack {
        NewCircleView(nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
    }
}

#Preview("Without Data") {
    let nearbyProfiles: [NearbyProfile] = []
    
    let onTapProfile: ((NearbyProfile) -> Void)? = { _ in print("Tapped") }
    
    NavigationStack {
        NewCircleView(nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
    }
}


