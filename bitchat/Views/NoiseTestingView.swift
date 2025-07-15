//
// NoiseTestingView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

#if DEBUG
struct NoiseTestingView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var testChecklist = NoiseTestingHelper.shared.getTestChecklist()
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("NOISE PROTOCOL TEST HELPER")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(textColor)
                .padding(.bottom)
            
            // Status Overview
            VStack(alignment: .leading, spacing: 8) {
                Text("CURRENT STATUS:")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor.opacity(0.7))
                
                ForEach(viewModel.connectedPeers, id: \.self) { peerID in
                    let nickname = viewModel.meshService.getPeerNicknames()[peerID] ?? "Unknown"
                    let status = viewModel.getEncryptionStatus(for: peerID)
                    
                    HStack {
                        Image(systemName: status.icon)
                            .font(.system(size: 12))
                            .foregroundColor(status == .noiseVerified ? Color.green : 
                                           status == .noiseSecured ? textColor :
                                           Color.red)
                        
                        Text("\(nickname): \(status.description)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        Spacer()
                    }
                }
                
                if viewModel.connectedPeers.isEmpty {
                    Text("No peers connected")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.gray)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            // Test Checklist
            ScrollView {
                Text(testChecklist)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            // Debug Actions
            HStack(spacing: 16) {
                Button("Force Handshake") {
                    // Trigger handshake with all peers by sending a broadcast announce
                    // This will cause all peers to re-exchange keys
                    viewModel.meshService.sendBroadcastAnnounce()
                }
                .foregroundColor(textColor)
                
                Button("Clear Sessions") {
                    // Clear all Noise sessions for testing
                    let noiseService = viewModel.meshService.getNoiseService()
                    for peerID in viewModel.connectedPeers {
                        noiseService.removePeer(peerID)
                    }
                    viewModel.peerEncryptionStatus.removeAll()
                }
                .foregroundColor(Color.orange)
                
                Button("Copy Logs") {
                    // Copy test results to clipboard
                    var logs = "NOISE PROTOCOL TEST RESULTS\n"
                    logs += "===========================\n\n"
                    logs += "Timestamp: \(Date())\n"
                    logs += "Connected Peers: \(viewModel.connectedPeers.count)\n\n"
                    
                    for peerID in viewModel.connectedPeers {
                        let nickname = viewModel.meshService.getPeerNicknames()[peerID] ?? "Unknown"
                        let status = viewModel.getEncryptionStatus(for: peerID)
                        logs += "\(nickname) (\(peerID)): \(status.description)\n"
                    }
                    
                    #if os(iOS)
                    UIPasteboard.general.string = logs
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logs, forType: .string)
                    #endif
                }
                .foregroundColor(textColor)
                
                
                Spacer()
            }
        }
        .padding()
        .frame(width: 500, height: 600)
        .background(backgroundColor)
    }
}
#endif