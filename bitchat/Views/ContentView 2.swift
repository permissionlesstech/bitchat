//
//  ContentView.swift
//  Circle
//
//  Created by Wentao Guo on 14/08/25.
//
import SwiftUI

struct Homepage: View {
    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(Color.brandPrimary)

     
        tabBarAppearance.stackedLayoutAppearance.normal.iconColor = UIColor(
            Color.white
        ).withAlphaComponent(0.6)
        tabBarAppearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(Color.white).withAlphaComponent(0.6)
        ]

   
        tabBarAppearance.stackedLayoutAppearance.selected.iconColor = .white
        tabBarAppearance.stackedLayoutAppearance.selected.titleTextAttributes =
            [
                .foregroundColor: UIColor.white
            ]

        UITabBar.appearance().standardAppearance = tabBarAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        }
    }

    var body: some View {
        TabView {
            ChatsView()
                .tabItem {
                    Image("message-question")
                        .renderingMode(.template)
                    Text("Chats")
                }
            Text("Profile")
                .tabItem {
                    Image("personalcard")
                        .renderingMode(.template)
                    Text("Profile")
                }
        }
        .tint(.brandPrimary)
    }
}

#Preview {
    Homepage()
}
