//
// FingerprintView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct FingerprintView: View {
    @ObservedObject var viewModel: ChatViewModel
    let peerID: String
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var themeManager: ThemeManager
    
    private var textColor: Color {
        themeManager.primaryTextColor(for: colorScheme)
    }
    
    private var backgroundColor: Color {
        themeManager.backgroundColor(for: colorScheme)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("SECURITY VERIFICATION")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Spacer()
                
                Button("DONE") {
                    dismiss()
                }
                .foregroundColor(textColor)
            }
            .padding()
            
            VStack(alignment: .leading, spacing: 16) {
                // Peer info
                let peerNickname = viewModel.meshService.getPeerNicknames()[peerID] ?? "Unknown"
                let encryptionStatus = viewModel.getEncryptionStatus(for: peerID)
                
                HStack {
                    if let icon = encryptionStatus.icon {
                        Image(systemName: icon)
                            .font(.system(size: 20))
                            .foregroundColor(encryptionStatus == .noiseVerified ? themeManager.successColor(for: colorScheme) : textColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peerNickname)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        Text(encryptionStatus.description)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                    }
                    
                    Spacer()
                }
                .padding()
                .background(themeManager.secondaryBackgroundColor(for: colorScheme).opacity(0.1))
                .cornerRadius(8)
                
                // Their fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text("THEIR FINGERPRINT:")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                    
                    if let fingerprint = viewModel.getFingerprint(for: peerID) {
                        Text(formatFingerprint(fingerprint))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(themeManager.secondaryBackgroundColor(for: colorScheme).opacity(0.1))
                            .cornerRadius(8)
                            .contextMenu {
                                Button("Copy") {
                                    #if os(iOS)
                                    UIPasteboard.general.string = fingerprint
                                    #else
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    #endif
                                }
                            }
                    } else {
                        Text("not available - handshake in progress")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(themeManager.warningColor(for: colorScheme))
                            .padding()
                    }
                }
                
                // My fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR FINGERPRINT:")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                    
                    let myFingerprint = viewModel.getMyFingerprint()
                    Text(formatFingerprint(myFingerprint))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(themeManager.secondaryBackgroundColor(for: colorScheme).opacity(0.1))
                        .cornerRadius(8)
                        .contextMenu {
                            Button("Copy") {
                                #if os(iOS)
                                UIPasteboard.general.string = myFingerprint
                                #else
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(myFingerprint, forType: .string)
                                #endif
                            }
                        }
                }
                
                // Verification status
                if encryptionStatus == .noiseSecured || encryptionStatus == .noiseVerified {
                    let isVerified = encryptionStatus == .noiseVerified
                    
                    VStack(spacing: 12) {
                        Text(isVerified ? "✓ VERIFIED" : "⚠️ NOT VERIFIED")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(isVerified ? themeManager.successColor(for: colorScheme) : themeManager.warningColor(for: colorScheme))
                            .frame(maxWidth: .infinity)
                        
                        Text(isVerified ? 
                             "you have verified this person's identity." :
                             "compare these fingerprints with \(peerNickname) using a secure channel.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                        
                        if !isVerified {
                            Button(action: {
                                viewModel.verifyFingerprint(for: peerID)
                                dismiss()
                            }) {
                                Text("MARK AS VERIFIED")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(themeManager.backgroundColor(for: colorScheme))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(themeManager.successColor(for: colorScheme))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.top)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: 500) // Constrain max width for better readability
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    
    private func formatFingerprint(_ fingerprint: String) -> String {
        // Convert to uppercase and format into 4 lines (4 groups of 4 on each line)
        let uppercased = fingerprint.uppercased()
        var formatted = ""
        
        for (index, char) in uppercased.enumerated() {
            // Add space every 4 characters (but not at the start)
            if index > 0 && index % 4 == 0 {
                // Add newline after every 16 characters (4 groups of 4)
                if index % 16 == 0 {
                    formatted += "\n"
                } else {
                    formatted += " "
                }
            }
            formatted += String(char)
        }
        
        return formatted
    }
}
