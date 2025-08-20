//
//  ContentView.swift
//  Circle
//
//  Created by Wentao Guo on 14/08/25.
//
import SwiftUI

// MARK: - Main App Entry
struct ContentView2: View {
    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(Color.brandOrange)

     
        tabBarAppearance.stackedLayoutAppearance.normal.iconColor = UIColor(
            Color.white
        ).withAlphaComponent(0.4)
        tabBarAppearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(Color.white).withAlphaComponent(0.4)
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
            Text("Alerts")
                .tabItem {
                    Image("location")
                        .renderingMode(.template)
                    Text("location")
                }
            Text("Circles")
                .tabItem {
                    Image("person")
                        .renderingMode(.template)
                    Text("Person")
                }
            Text("Contacts")
                .tabItem {
                    Image("profile")
                        .renderingMode(.template)
                    Text("Profile")
                }
        }
        .tint(.brandOrange)
    }
}

// MARK: - Preview
#Preview {
    ContentView2()
}
