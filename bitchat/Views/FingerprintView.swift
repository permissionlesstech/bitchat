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
    let peerID: PeerID
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private enum Strings {
        static let title: LocalizedStringKey = "fingerprint.title"
        static let theirFingerprint: LocalizedStringKey = "fingerprint.their_label"
        static let handshakePending: LocalizedStringKey = "fingerprint.handshake_pending"
        static let yourFingerprint: LocalizedStringKey = "fingerprint.your_label"
        static let copy: LocalizedStringKey = "common.copy"
        static let verifiedBadge: LocalizedStringKey = "fingerprint.badge.verified"
        static let notVerifiedBadge: LocalizedStringKey = "fingerprint.badge.not_verified"
        static let verifiedMessage: LocalizedStringKey = "fingerprint.message.verified"
        static func verifyHint(_ nickname: String) -> String {
            String(
                format: String(localized: "fingerprint.message.verify_hint", comment: "Instruction to compare fingerprints with a named peer"),
                locale: .current,
                nickname
            )
        }
        static let markVerified: LocalizedStringKey = "fingerprint.action.mark_verified"
        static let removeVerification: LocalizedStringKey = "fingerprint.action.remove_verification"
        static func unknownPeer() -> String {
            String(localized: "common.unknown", comment: "Label for an unknown peer")
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text(Strings.title)
                    .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 14, weight: .semibold))
                }
                .foregroundColor(textColor)
            }
            .padding()
            
            VStack(alignment: .leading, spacing: 16) {
                // Prefer short mesh ID for session/encryption status
                let statusPeerID = viewModel.getShortIDForNoiseKey(peerID)
                // Resolve a friendly name
                let peerNickname: String = {
                    if let p = viewModel.getPeer(byID: statusPeerID) { return p.displayName }
                    if let name = viewModel.meshService.peerNickname(peerID: statusPeerID) { return name }
                    if let data = peerID.noiseKey {
                        if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: data), !fav.peerNickname.isEmpty { return fav.peerNickname }
                        let fp = data.sha256Fingerprint()
                        if let social = viewModel.identityManager.getSocialIdentity(for: fp) {
                            if let pet = social.localPetname, !pet.isEmpty { return pet }
                            if !social.claimedNickname.isEmpty { return social.claimedNickname }
                        }
                    }
                    return Strings.unknownPeer()
                }()
                // Accurate encryption state based on short ID session
                let encryptionStatus = viewModel.getEncryptionStatus(for: statusPeerID)
                
                HStack {
                    if let icon = encryptionStatus.icon {
                        Image(systemName: icon)
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(encryptionStatus == .noiseVerified ? Color.green : textColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peerNickname)
                            .font(.bitchatSystem(size: 18, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        Text(encryptionStatus.description)
                            .font(.bitchatSystem(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                
                // Their fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.theirFingerprint)
                        .font(.bitchatSystem(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                    
                    if let fingerprint = viewModel.getFingerprint(for: statusPeerID) {
                        Text(formatFingerprint(fingerprint))
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .contextMenu {
                                Button(Strings.copy) {
                                    #if os(iOS)
                                    UIPasteboard.general.string = fingerprint
                                    #else
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    #endif
                                }
                            }
                    } else {
                        Text(Strings.handshakePending)
                            .font(.bitchatSystem(size: 14, design: .monospaced))
                            .foregroundColor(Color.orange)
                            .padding()
                    }
                }

                // My fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.yourFingerprint)
                        .font(.bitchatSystem(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.7))
                    
                    let myFingerprint = viewModel.getMyFingerprint()
                    Text(formatFingerprint(myFingerprint))
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .contextMenu {
                            Button(Strings.copy) {
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
                        Text(isVerified ? Strings.verifiedBadge : Strings.notVerifiedBadge)
                            .font(.bitchatSystem(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(isVerified ? Color.green : Color.orange)
                            .frame(maxWidth: .infinity)
                        
                        Group {
                            if isVerified {
                                Text(Strings.verifiedMessage)
                            } else {
                                Text(Strings.verifyHint(peerNickname))
                            }
                        }
                            .font(.bitchatSystem(size: 12, design: .monospaced))
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
                                Text(Strings.markVerified)
                                    .font(.bitchatSystem(size: 14, weight: .bold, design: .monospaced))
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
                                Text(Strings.removeVerification)
                                    .font(.bitchatSystem(size: 14, weight: .bold, design: .monospaced))
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
