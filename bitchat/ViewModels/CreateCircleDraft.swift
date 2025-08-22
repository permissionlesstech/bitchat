//
//  CreateCircleDraft.swift
//  bitchat
//
//  Created by Saputra on 21/08/25.
//

import Foundation
import SwiftUI

final class CreateCircleDraft: ObservableObject {
    @Published var name: String
    @Published var color: Color
    @Published var selectedMembers: [NearbyProfile] = []
    @Published var about: String = ""
    
    init(name: String = "", color: Color = .blue, selectedMembers: [NearbyProfile] = []) {
        self.name = name
        self.color = color
        self.selectedMembers = selectedMembers
    }
}

extension CreateCircleDraft {
    func isSelected(_ p : NearbyProfile) -> Bool {
        selectedMembers.contains { $0.id == p.id }
    }
    
    func toggle(_ p: NearbyProfile) {
        if let i = selectedMembers.firstIndex(where: { $0.id == p.id }) {
            selectedMembers.remove(at: i)
        } else {
            selectedMembers.append(p)
        }
    }
}
