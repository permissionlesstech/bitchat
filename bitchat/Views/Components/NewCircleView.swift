//
//  NewCircleView.swift
//  bitchat
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

enum CreateCircleStep: Int, CaseIterable {
    case nearby = 0
    case about
    case name
    case review
    
    var title: String {
        switch self {
        case .nearby: return "Nearby"
        case .about: return "About"
        case .name: return "Group Information"
        case .review: return "Review"
        }
    }
    
    func next() -> CreateCircleStep {
        let all = Self.allCases
        let i = min(self.rawValue + 1, all.count - 1)
        return all[i]
    }
    
    func back() -> CreateCircleStep {
        let i = max(self.rawValue - 1, 0)
        return Self.allCases[i]
    }
}

struct NewCircleView: View {
    @StateObject private var draft: CreateCircleDraft
    @State private var step: CreateCircleStep = .nearby
    @State private var showSheet = true
    let nearbyProfiles: [NearbyProfile]
    let onTapProfile: ((NearbyProfile) -> Void)?
    
    init(
        draft: CreateCircleDraft = CreateCircleDraft(),
        nearbyProfiles: [NearbyProfile],
        onTapProfile: ((NearbyProfile) -> Void)? = nil
    ) {
        _draft = StateObject(wrappedValue: draft)
        self.nearbyProfiles = nearbyProfiles
        self.onTapProfile = onTapProfile
    }
    
    var body: some View {
        ZStack(alignment: .top){
            Color.white
            VStack {
                Image("bubble")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 400, height: 350)
                    .offset(x:40)
            }
            VStack(spacing: 8) {
                EditableCircleAvatar(onEdit: { showSheet = true }, color: $draft.color)
                Text(draft.name)
                    .font(.title3.weight(.semibold))
            }
            .padding(.top, 120)
        }
        .ignoresSafeArea(.all)
                    .navigationTitle("New Circle")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        .sheet(isPresented: $showSheet) {
            if #available(iOS 16.4, *) {
                CreateCircleSheetContainer(draft: draft, step: $step, nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
                    .presentationDetents([.fraction(0.75)])
                    #if os(iOS)
                    .presentationCornerRadius(24)
                    .presentationBackgroundInteraction(.enabled)
                    #endif
                    .presentationDragIndicator(.visible)
                    .id(step)
            } else {
                CreateCircleSheetContainer(draft: draft, step: $step, nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
                    .presentationDetents([.fraction(0.75)])
                    .presentationDragIndicator(.visible)
                    .id(step)
            }
        }
    }
}

struct CreateCircleSheetContainer: View {
    @ObservedObject var draft: CreateCircleDraft
    @Binding var step: CreateCircleStep
    
    let nearbyProfiles: [NearbyProfile]
    let onTapProfile: ((NearbyProfile) -> Void)?
    
    @State private var showEditMembers = false
    
    var body: some View {
        
        GeometryReader { geo in
            let bottomInset = geo.safeAreaInsets.bottom
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if step != .name && step != . review {
                        HStack {
                            SectionHeaderView(title: step.title)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 48)
                    }
                    
                    Group {
                        switch step {
                        case .nearby:
                            StepNearbyGrid(
                                profiles: nearbyProfiles,
                                onTap: onTapProfile
                            )
                        case .about:
                            StepAbout(text: $draft.about)
                        case .name:
                            StepName(color: $draft.color, name: $draft.name)
                        case .review:
                            StepReview(draft: draft, onEditMembers: { showEditMembers = true }, onEditAbout: { step = .about })
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    Spacer(minLength: 100)
                }
                .padding(.top, 12)
                .background(Color.white)
            }
            
            .overlay(alignment: .bottom) {
                HStack {
                    if step != .nearby {
                        PrimaryButton(title: "Back") {
                            step = step.back()
                        }
                    }
                    Spacer()
                    PrimaryButton(title: step == .review ? "Done" : "Next") {
                        if step == .review {
                            // TODO: submit create circle
                        } else {
                            step = step.next()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .padding(.bottom, max(12, bottomInset))
            }
            
            .sheet(isPresented: $showEditMembers) {
                MembersEditSheet(draft: draft, nearby: nearbyProfiles, onDone: { showEditMembers = false} )
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
            }
        }
                        .background(Color.white)
    }
}

struct StepNearbyGrid: View {
    let profiles: [NearbyProfile]
    let onTap: ((NearbyProfile) -> Void)?

    private let cardSize: CGFloat = 72
    private let spacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if profiles.isEmpty {
                NearbyEmptyView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize), spacing: spacing, alignment: .top)], alignment: .leading, spacing: spacing) {
                    ForEach(profiles) { p in
                        VStack(spacing: 6) {
                            NearbyProfileCardView(profile: p) {
                                onTap?(p)
                            }
                            .frame(width: cardSize + 24)
                        }
                        .accessibilityLabel("\(p.name)")
//                        .accessibilityValue(selected.contains(p.id) ? "Selected" : "Not selected")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct StepAbout: View {
    @Binding var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoBox(text: $text, placeholder: "Description of the group")
        }
    }
}

struct StepName: View {
    @Binding var color: Color
    @Binding var name: String
    let availableColors: [Color] = [.orange, .blue, .gray, .pink, .yellow]
    
    var body: some View {
        VStack(spacing: 16) {
                InputLabel(title: "Group Name")
                RoundedTextField(text: $name, placeholder: "Name")
                
                InputLabel(title: "Select Color")
                ColorPickerRow(selectedColor: $color, colors: availableColors)
            }
        .padding(.top, 48)
        .padding(.horizontal)
    }
}

struct ColorPickerRow: View {
    @Binding var selectedColor: Color
    let colors: [Color]
    
    private let circleSize: CGFloat = 40
    private let borderWidth: CGFloat = 3
    
    var body: some View {
        HStack(spacing: 20) {
            ForEach(colors, id: \.self) { c in
                Circle()
                    .fill(c)
                    .frame(width: circleSize, height: circleSize)
                    .overlay(
                        Circle().stroke(selectedColor == c ? c : .clear, lineWidth: borderWidth)
                    )
                    .onTapGesture {
                        selectedColor = c
                    }
            }
        }
    }
}

struct StepReview: View {
    var draft: CreateCircleDraft
    private let cardSize: CGFloat = 72
    private let spacing: CGFloat = 16
    var onEditMembers: (() -> Void)?
    var onEditAbout: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Members (\(draft.selectedMembers.count))")
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    CircleIconButtonView(
                        systemIcon: "pencil",
                        diameter: 28,
                        accessibilityLabel: "Edit About",
                        accessibilityText: "Edit"
                    ) { onEditMembers?() }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize), spacing: spacing, alignment: .top)], alignment: .leading, spacing: spacing) {
                    ForEach(draft.selectedMembers) { m in
                        VStack(spacing: 6) {
                            NearbyProfileCardView(profile: m)
                                .frame(width: cardSize + 24)
                        }
                        .accessibilityLabel("\(m.name)")
                        //                        .accessibilityValue(selected.contains(p.id) ? "Selected" : "Not selected")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text("About")
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    CircleIconButtonView(
                        systemIcon: "pencil",
                        diameter: 28,
                        accessibilityLabel: "Edit About",
                        accessibilityText: "Edit"
                    ) {
                        onEditAbout?()
                    }
                }
                InfoBox(text: .constant(draft.about), placeholder: nil, isDisabled: true)
            }
        }
        .padding(.top, 48)
        .padding(.horizontal)
    }
}

struct MembersEditSheet: View {
    @ObservedObject var draft: CreateCircleDraft
    let nearby: [NearbyProfile]
    var onDone: () -> Void

    private let cardSize: CGFloat = 64
    private let spacing: CGFloat = 16

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeaderView(title: "Nearby")

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(nearby) { p in
                                    NearbyProfileCardView(profile: p, size: cardSize, ringWidth: 3) {
                                        draft.toggle(p)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Members (\(draft.selectedMembers.count))")
                                .font(.system(.largeTitle, weight: .bold))
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                        }

                        if draft.selectedMembers.isEmpty {
                            Text("No members yet. Pick from Nearby above.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(draft.selectedMembers) { m in
                                    MemberRow(profile: m)
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Edit Members")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    PrimaryButton(title: "Done", action: onDone)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
//                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Done")
                .accessibilityHint("Close members editor")
            }
        }
    }
}

private struct MemberRow: View {
    let profile: NearbyProfile
    var size: CGFloat = 64
    var ringWidth: CGFloat = 4
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(.pink, lineWidth: ringWidth)
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
            Text(profile.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(profile.team)")
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
    
    let preselected = Array(nearbyProfiles.prefix(3))
    
    let onTapProfile: ((NearbyProfile) -> Void)? = { _ in print("Tapped") }
    
    NavigationStack {
        NewCircleView(draft: CreateCircleDraft(name: "My Circle", color: .blue, selectedMembers: preselected), nearbyProfiles: nearbyProfiles, onTapProfile: {_ in })
    }
}

#Preview("Without Data") {
    let nearbyProfiles: [NearbyProfile] = []
    
    let onTapProfile: ((NearbyProfile) -> Void)? = { _ in print("Tapped") }
    
    NavigationStack {
        NewCircleView(nearbyProfiles: nearbyProfiles, onTapProfile: onTapProfile)
    }
}


