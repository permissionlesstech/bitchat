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
                Text(String(localized: "fp.title"))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityLabel(String(localized: "accessibility.close"))
                }
                .foregroundColor(textColor)
            }
            .padding()
            
            VStack(alignment: .leading, spacing: 16) {
                // Prefer short mesh ID for session/encryption status
                let statusPeerID: String = {
                    if peerID.count == 64, let short = viewModel.getShortIDForNoiseKey(peerID) { return short }
                    return peerID
                }()
                // Resolve a friendly name
                let peerNickname: String = {
                    if let p = viewModel.getPeer(byID: statusPeerID) { return p.displayName }
                    if let name = viewModel.meshService.peerNickname(peerID: statusPeerID) { return name }
                    if peerID.count == 64, let data = Data(hexString: peerID) {
                        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: data), !fav.peerNickname.isEmpty { return fav.peerNickname }
                        let fp = data.sha256Fingerprint()
                        if let social = viewModel.identityManager.getSocialIdentity(for: fp) {
                            if let pet = social.localPetname, !pet.isEmpty { return pet }
                            if !social.claimedNickname.isEmpty { return social.claimedNickname }
                        }
                    }
                    return String(localized: "common.unknown")
                }()
                // Accurate encryption state based on short ID session
                let encryptionStatus = viewModel.getEncryptionStatus(for: statusPeerID)
                
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
                
                // Their fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "fp.their_fingerprint"))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                    
                    if let fingerprint = viewModel.getFingerprint(for: statusPeerID) {
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
                                Button(action: {
                                    #if os(iOS)
                                    UIPasteboard.general.string = fingerprint
                                    #else
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    #endif
                                }) {
                                    Text(String(localized: "common.copy"))
                                        .accessibilityLabel(String(localized: "accessibility.button.copy"))
                                }
                            }
                    } else {
                        Text(String(localized: "fp.not_available"))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color.orange)
                            .padding()
                    }
                }
                
                // My fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "fp.your_fingerprint"))
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
                            Button(action: {
                                #if os(iOS)
                                UIPasteboard.general.string = myFingerprint
                                #else
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(myFingerprint, forType: .string)
                                #endif
                            }) {
                                Text(String(localized: "common.copy"))
                                    .accessibilityLabel(String(localized: "accessibility.button.copy"))
                            }
                        }
                }
                
                // Verification status
                if encryptionStatus == .noiseSecured || encryptionStatus == .noiseVerified {
                    let isVerified = encryptionStatus == .noiseVerified
                    
                    VStack(spacing: 12) {
                        Text(isVerified ? String(localized: "fp.verified") : String(localized: "fp.not_verified"))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(isVerified ? Color.green : Color.orange)
                            .frame(maxWidth: .infinity)
                        
                        Text(isVerified ?
                             String(localized: "fp.verified_message") :
                             String.localizedStringWithFormat(String(localized: "fp.compare_fingerprints_with_name"), peerNickname))
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
                                Text(String(localized: "fp.mark_verified"))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.green)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Button(action: {
                                viewModel.unverifyFingerprint(for: peerID)
                                dismiss()
                            }) {
                                Text(String(localized: "fp.remove_verification_button"))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.red)
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
