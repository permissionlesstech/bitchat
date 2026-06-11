//
// FingerprintView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitFoundation

struct FingerprintView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    let peerID: PeerID
    @Environment(\.dismiss) var dismiss
    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }

    private var backgroundColor: Color { palette.background }

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
        let fingerprintState = verificationModel.fingerprintPresentation(for: peerID)

        VStack(spacing: 20) {
            // Header
            HStack {
                Text(Strings.title)
                    .bitchatFont(size: 16, weight: .bold)
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
                HStack {
                    if let icon = fingerprintState.encryptionStatus.icon {
                        Image(systemName: icon)
                            .font(.bitchatSystem(size: 20))
                            .foregroundColor(fingerprintState.encryptionStatus == .noiseVerified ? Color.green : textColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fingerprintState.peerNickname)
                            .bitchatFont(size: 18, weight: .semibold)
                            .foregroundColor(textColor)
                        
                        Text(fingerprintState.encryptionStatus.description)
                            .bitchatFont(size: 12)
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
                        .bitchatFont(size: 12, weight: .bold)
                        .foregroundColor(textColor.opacity(0.7))
                    
                    if let fingerprint = fingerprintState.theirFingerprint {
                        Text(formatFingerprint(fingerprint))
                            .bitchatFont(size: 14)
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
                            .bitchatFont(size: 14)
                            .foregroundColor(Color.orange)
                            .padding()
                    }
                }

                // My fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.yourFingerprint)
                        .bitchatFont(size: 12, weight: .bold)
                        .foregroundColor(textColor.opacity(0.7))
                    
                    Text(formatFingerprint(fingerprintState.myFingerprint))
                        .bitchatFont(size: 14)
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
                                UIPasteboard.general.string = fingerprintState.myFingerprint
                                #else
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fingerprintState.myFingerprint, forType: .string)
                                #endif
                            }
                        }
                }
                
                // Verification status
                if fingerprintState.canToggleVerification {
                    VStack(spacing: 12) {
                        Text(fingerprintState.isVerified ? Strings.verifiedBadge : Strings.notVerifiedBadge)
                            .bitchatFont(size: 14, weight: .bold)
                            .foregroundColor(fingerprintState.isVerified ? Color.green : Color.orange)
                            .frame(maxWidth: .infinity)
                        
                        Group {
                            if fingerprintState.isVerified {
                                Text(Strings.verifiedMessage)
                            } else {
                                Text(Strings.verifyHint(fingerprintState.peerNickname))
                            }
                        }
                            .bitchatFont(size: 12)
                            .foregroundColor(textColor.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                        
                        if !fingerprintState.isVerified {
                            Button(action: {
                                verificationModel.verifyFingerprint(for: peerID)
                                dismiss()
                            }) {
                                Text(Strings.markVerified)
                                    .bitchatFont(size: 14, weight: .bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.green)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            Button(action: {
                                verificationModel.unverifyFingerprint(for: peerID)
                                dismiss()
                            }) {
                                Text(Strings.removeVerification)
                                    .bitchatFont(size: 14, weight: .bold)
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
        .themedSheetBackground()
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
