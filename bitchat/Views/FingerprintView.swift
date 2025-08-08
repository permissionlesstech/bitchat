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
    @State private var petnameText: String = ""
    @FocusState private var isPetnameFieldFocused: Bool
    
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
                            .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : textColor)
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
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)

                // Petname management
                VStack(alignment: .leading, spacing: 8) {
                    Text("PERSONAL NAME:")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("enter a name for this person", text: $petnameText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(textColor)
                                .focused($isPetnameFieldFocused)
                                .autocorrectionDisabled(true)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .onSubmit {
                                    viewModel.setPetname(peerID: peerID, petname: petnameText.isEmpty ? nil : petnameText)
                                }
                                .onChange(of: petnameText) { newValue in
                                    // Auto-save as user types (debounced)
                                    viewModel.setPetname(peerID: peerID, petname: newValue.isEmpty ? nil : newValue)
                                }

                            if !petnameText.isEmpty || viewModel.getPetname(peerID: peerID) != nil {
                                Button("CLEAR") {
                                    petnameText = ""
                                    viewModel.clearPetname(peerID: peerID)
                                }
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(Color.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                                .buttonStyle(.plain)
                            }
                        }

                        Text("claimed name: \(peerNickname)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.6))

                        Text("this personal name is stored locally and only you can see it. it will persist even if they change their claimed name or peer id.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.5))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
                
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
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color.orange)
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
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(isVerified ? Color.green : Color.orange)
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
        .onAppear {
            // Initialize petname text field with existing petname
            petnameText = viewModel.getPetname(peerID: peerID) ?? ""
        }
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
