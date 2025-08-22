//
//  ChatView.swift
//  Circle
//
//  Created by Wentao Guo on 14/08/25.
//

import SwiftUI
struct ChatsView: View {
    let sample: [ChatItem] = [
        ChatItem(title: "Public Channel",
                 subtitle: "Saputra Team 1 is typing...",
                 time: "19:45", unreadCount: 1, pinned: true,
                 iconSystemName: "megaphone.fill",
                 iconBackground: Color(.systemYellow)),
        ChatItem(title: "Design",
                 subtitle: "Ayu: uploaded a new mock",
                 time: "18:12", unreadCount: 0, pinned: false,
                 iconSystemName: "paintbrush.fill",
                 iconBackground: Color(.systemTeal))
    ]

    init() {
        #if os(iOS)
        let appearance = UISegmentedControl.appearance()
        appearance.selectedSegmentTintColor = UIColor(Color.orange)
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.gray,
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        UISegmentedControl.appearance().setTitleTextAttributes(
            normalAttrs, for: .normal)
        
        let selectedAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        UISegmentedControl.appearance().setTitleTextAttributes(
            selectedAttrs, for: .selected)
        #endif
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                NearYouSectionView(profiles: [
                    .init(name: "Saputra", team: "Team 1", image: Image("picture1"), initials: "SU"),
                    .init(name: "Ayu",     team: "Team 2", image: Image("picture2"), initials: "AY"),
                    .init(name: "Putri",   team: "Team 3", image: Image("picture3"), initials: "PT"),
                    .init(name: "Agus",    team: "Team 4", image: Image("picture4"), initials: "AG")
                ],
                onTapProfile: { _ in print("Tapped") })
                
                ChatsSectionView(items: sample)
                
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    CircleIconButtonView()
                }
            }
        }
    }
}

#Preview {
    ChatsView()
}
