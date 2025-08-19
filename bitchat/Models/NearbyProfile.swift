//
//  NearbyProfileModel.swift
//  bitchat_iOS
//
//  Created by Saputra on 19/08/25.
//

import Foundation
import SwiftUI

struct NearbyProfile: Identifiable {
    let id = UUID()
    let name: String
    let team: String
    let image: Image?
    let initials: String
}
