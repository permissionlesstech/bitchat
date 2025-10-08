//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct BitchatApp: View {
    @StateObject private var chatViewModel = BitchatViewModel()
    @State var canStart: Bool = false
    
    var body: some View {
        if canStart {
            BitchatContentView()
                .environmentObject(chatViewModel)
                .onAppear {
                    // Inject live Noise service into VerificationService to avoid creating new BLE instances
                    
                    // Check for shared content
                    chatViewModel.startServices()
                }
        }
        else {
            LoadingView()
                .onAppear {
                    canStart = true
                }
        }
    }
}
