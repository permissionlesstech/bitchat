//
//  ChatView.swift
//  Circle
//
//  Created by Wentao Guo on 14/08/25.
//
import SwiftUI

struct Chat: Identifiable {
    enum Kind { case person, circle }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let time: String
    let avatar: String  // image name or emoji fallback
    let isTyping: Bool
    let unreadCount: Int
}

// MARK: - Sample Data
private let sampleChats: [Chat] = [
    .init(
        kind: .person, title: "Mom 💕", subtitle: "Mom is typing...",
        time: "19:45", avatar: "person.circle.fill", isTyping: true,
        unreadCount: 1),
    .init(
        kind: .person, title: "Daddy", subtitle: "✔️ I mean he wrecked it! 😳",
        time: "19:42", avatar: "person.crop.circle.fill", isTyping: false,
        unreadCount: 0),
    .init(
        kind: .person, title: "Brother", subtitle: "Say hi to your mom for me.",
        time: "18:23", avatar: "person.crop.circle.badge.checkmark",
        isTyping: false, unreadCount: 0),
    .init(
        kind: .person, title: "Mom", subtitle: "📍 Location", time: "08:24",
        avatar: "person.crop.circle", isTyping: false, unreadCount: 0),
    .init(
        kind: .person, title: "Dave", subtitle: "Thanks bro!", time: "08:01",
        avatar: "person.circle", isTyping: false, unreadCount: 0),
    .init(
        kind: .person, title: "Sister", subtitle: "✔️ Ok!", time: "Yesterday",
        avatar: "person.circle.fill", isTyping: false, unreadCount: 0),
    .init(
        kind: .circle, title: "Circle 1", subtitle: "Saputra:",
        time: "Yesterday", avatar: "person.2.circle", isTyping: false,
        unreadCount: 0),
]

private let sampleCircles: [Chat] = [
    .init(
        kind: .circle, title: "Family Circle", subtitle: "✔️ Ok!", time: "19:40",
        avatar: "person.3.fill", isTyping: false, unreadCount: 0),
    .init(
        kind: .circle, title: "Friend Circle",
        subtitle: "⚠️ Peringatan Tsunami\n[07/30 07:25] Terjadi gempa ......",
        time: "19:42", avatar: "person.3", isTyping: false, unreadCount: 0),
]

// MARK: - Colors
extension Color {
    static let brandOrange = Color(red: 1.0, green: 0.58, blue: 0.27)  // #FF9444
    static let chipBG = Color(uiColor: .systemGray6)
}

// MARK: - Tabs / Filters
enum ChatsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case circle = "Circle"
    var id: String { rawValue }
}

// MARK: - Chats Screen
struct ChatsView: View {
    @State private var isPresent = false
    @State private var isNewView = false
    @State private var filter: ChatsFilter = .all
    @State private var allChats: [Chat] = sampleChats
    @State private var circleChats: [Chat] = sampleCircles

    init() {
        let appearance = UISegmentedControl.appearance()
        appearance.selectedSegmentTintColor = UIColor(Color.brandOrange)
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

    }

    var body: some View {
        VStack(spacing: 0) {
            header
            segmented
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            Divider().opacity(0)

            List(currentData) { chat in
                ChatRow(chat: chat)
                    .listRowInsets(
                        EdgeInsets(
                            top: 10, leading: 20, bottom: 10, trailing: 16))
            }
            .listStyle(.plain)
        }
        .background(Color.white)
        .confirmationDialog(
            "", isPresented: $isPresent, titleVisibility: .hidden
        ) {
            Button("New Contact") {isNewView = true}
            Button("Create New Circle") {}
            Button("Join Circle") {}
        }
        .sheet(isPresented: $isNewView) {
            NewContact()
                .presentationDetents([.fraction(0.999)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .interactiveDismissDisabled(false)
        }
    }

    private var currentData: [Chat] {
        switch filter {
        case .all: return allChats
        case .unread:
            return allChats.filter { $0.unreadCount > 0 || $0.isTyping }
        case .circle: return circleChats
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(alignment: .top) {

            Text("Chats")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.brandOrange)
                .padding(.top, 32)
                .padding(.bottom, 20)

            Spacer()

            VStack(spacing: 8) {
                Button {
                    isPresent = true
                } label: {
                    Image("TopButton")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .opacity(0.6)
                }

            }
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    // MARK: Segmented (pill style)
    private var segmented: some View {
        Picker("", selection: $filter) {
            ForEach(ChatsFilter.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 8)

    }

}

// MARK: - Row
struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(chat.time)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if chat.unreadCount > 0 {
                        UnreadBadge(count: chat.unreadCount)
                    }
                }

                Text(chat.isTyping ? "Mom is typing..." : chat.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(
                        chat.isTyping
                            ? AnyShapeStyle(.secondary.opacity(0.8))
                            : AnyShapeStyle(.secondary)
                    )

            }
        }
    }

    private var avatar: some View {
        ZStack {
            if chat.kind == .circle {
                Image(systemName: chat.avatar)
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.chipBG))
                    .clipShape(Circle())
            } else {
                Image(systemName: chat.avatar)
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
        }
    }
}

// MARK: - Unread Badge
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text(String(count))
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.brandOrange))
            .foregroundStyle(.white)
            .overlay(
                Capsule().stroke(.white, lineWidth: 1)
            )
            .padding(.leading, 6)
    }
}

// MARK: - Preview
#Preview {
    ChatsView()
}
