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
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("SECURITY VERIFICATION")
                    .monospaceFont(size: 16, weight: .bold)
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
                            .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : textColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peerNickname)
                            .monospaceFont(size: 18, weight: .semiBold)
                            .foregroundColor(textColor)
                        
                        Text(encryptionStatus.description)
                            .monospaceFont(size: 12)
                            .foregroundColor(textColor.opacity(0.7))
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                
                // Their fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text("THEIR FINGERPRINT:")
                        .monospaceFont(size: 12, weight: .bold)
                        .foregroundColor(textColor.opacity(0.7))
                    
                    if let fingerprint = viewModel.getFingerprint(for: peerID) {
                        Text(formatFingerprint(fingerprint))
                            .monospaceFont(size: 14)
                            .foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.1))
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
                            .monospaceFont(size: 14)
                            .foregroundColor(Color.orange)
                            .padding()
                    }
                }
                
                // My fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR FINGERPRINT:")
                        .monospaceFont(size: 12, weight: .bold)
                        .foregroundColor(textColor.opacity(0.7))
                    
                    let myFingerprint = viewModel.getMyFingerprint()
                    Text(formatFingerprint(myFingerprint))
                        .monospaceFont(size: 14)
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
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
                            .monospaceFont(size: 14, weight: .bold)
                            .foregroundColor(isVerified ? Color.green : Color.orange)
                            .frame(maxWidth: .infinity)
                        
                        Text(isVerified ? 
                             "you have verified this person's identity." :
                             "compare these fingerprints with \(peerNickname) using a secure channel.")
                            .monospaceFont(size: 12)
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
                                    .monospaceFont(size: 14, weight: .bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.green)
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
