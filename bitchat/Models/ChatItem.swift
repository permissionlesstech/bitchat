//
//  ChatItem.swift
//  bitchat_iOS
//
//  Created by Saputra on 20/08/25.
//

import SwiftUI

struct ChatItem: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var time: String?
    var unreadCount: Int = 0
    var pinned: Bool = false
    var iconSystemName: String = "megaphone.fill"
    var iconBackground: Color = Color(.systemYellow)
}
