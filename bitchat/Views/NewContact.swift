//
//  NewContact.swift
//  Circle
//
//  Created by Wentao Guo on 15/08/25.
//

import SwiftUI

// MARK: - Model
struct Contact: Identifiable {
    let id = UUID()
    let name: String
    let status: String
    let avatarSystem: String
}

// MARK: - Screen
struct NewContact: View {
    enum Tab: String, CaseIterable { case list = "Contact List", add = "Add Contact" }
    @State private var current: Tab = .list
    @Environment(\.dismiss) private var dismiss

    private let contacts: [Contact] = (0..<7).map { _ in
        .init(name: "AAAAA", status: "Status", avatarSystem: "person.circle.fill")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            segment
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)

            Group {
                switch current {
                case .list: contactList
                case .add: nearYouEmptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
        
            LinearGradient(
                colors: [.clear, Color.orange.opacity(0.06)],
                startPoint: .center, endPoint: .bottom
            )
        )
    }

    // MARK: Header
    private var header: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.gray)

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.24, green: 0.24, blue: 0.26).opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    // MARK: Segment (pill style)
    private var segment: some View {
        HStack(spacing: 8) {
            ForEach([Tab.list, Tab.add], id: \.self) { tab in
                let selected = (current == tab)
                Button {
                    withAnimation(.snappy) { current = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(selected ? Color.orange : Color(.systemGray5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
    }

    // MARK: Contact List
    private var contactList: some View {
        List {
            ForEach(contacts) { c in
                HStack(spacing: 12) {
                    Image(systemName: c.avatarSystem)
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color(.systemGray5)))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 16, weight: .semibold))
                        Text(c.status).font(.system(size: 12)).foregroundStyle(.secondary).italic()
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
    }

    // MARK: Near You Empty State
    private var nearYouEmptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Near You")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle().fill(Color(.systemGray6)).frame(width: 44, height: 44)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Seems like there are no other devices\nnear you right now.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview
#Preview {
    NewContact()
}
