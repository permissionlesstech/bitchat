//
// IdentityBackupViews.swift
// bitchat
//
// Settings sheet for passphrase-encrypted identity export / restore (#183).
// Visual language matches AppInfoView + VerificationSheetView: themed palette,
// bitchatFont, secondary-opacity cards, SheetCloseButton.
//

import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum IdentityBackupMode: String, Identifiable, Equatable {
    case export
    case restore

    var id: String { rawValue }
}

/// Closures AppInfoView needs without taking a ChatViewModel dependency.
struct IdentityBackupActions {
    var currentFingerprint: () -> String
    var exportBackup: (_ passphrase: String, _ confirm: String) throws -> String
    var restoreBackup: (_ backup: String, _ passphrase: String) throws -> String
}

struct IdentityBackupSheet: View {
    let mode: IdentityBackupMode
    let actions: IdentityBackupActions
    @Binding var isPresented: Bool

    @ThemedPalette private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var backupText = ""
    @State private var exportedURI: String?
    @State private var compactToken: String?
    @State private var exportedFingerprint: String?
    @State private var restoredFingerprint: String?
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var showRestoreConfirm = false
    @State private var showScanner = false
    @State private var isBusy = false
    @State private var revealPassphrase = false

    private var accent: Color { palette.accent }
    private var textColor: Color { palette.primary }
    private var secondaryText: Color { palette.secondary }
    private var boxColor: Color { palette.secondary.opacity(0.12) }

    private enum Strings {
        static let exportTitle = String(
            localized: "identity_backup.sheet.export_title",
            defaultValue: "export identity",
            comment: "Title of the identity export sheet"
        )
        static let restoreTitle = String(
            localized: "identity_backup.sheet.restore_title",
            defaultValue: "restore identity",
            comment: "Title of the identity restore sheet"
        )
        static let exportIntro = String(
            localized: "identity_backup.sheet.export_intro",
            defaultValue: "encrypts your Noise, signing, and Nostr keys so you can move them to another phone. anyone with this backup and the passphrase becomes you on the network — keep both secret.",
            comment: "Intro copy on the identity export sheet"
        )
        static let restoreIntro = String(
            localized: "identity_backup.sheet.restore_intro",
            defaultValue: "replaces the cryptographic identity on this device with the one in the backup. do not run the same backup on two devices at once — sessions will collide.",
            comment: "Intro copy on the identity restore sheet"
        )
        static let passphrase = String(
            localized: "identity_backup.sheet.passphrase",
            defaultValue: "passphrase",
            comment: "Label for the backup passphrase field"
        )
        static let confirmPassphrase = String(
            localized: "identity_backup.sheet.confirm_passphrase",
            defaultValue: "confirm passphrase",
            comment: "Label for the confirm-passphrase field on export"
        )
        static let suggest = String(
            localized: "identity_backup.sheet.suggest",
            defaultValue: "suggest",
            comment: "Button that fills a high-entropy suggested passphrase"
        )
        static let createBackup = String(
            localized: "identity_backup.sheet.create_backup",
            defaultValue: "create encrypted backup",
            comment: "Primary button that builds the encrypted identity backup"
        )
        static let restoreAction = String(
            localized: "identity_backup.sheet.restore_action",
            defaultValue: "restore identity",
            comment: "Primary button that decrypts and installs the backup"
        )
        static let backupPlaceholder = String(
            localized: "identity_backup.sheet.backup_placeholder",
            defaultValue: "paste bitchat://identity-backup/… or bitchat1id:…",
            comment: "Placeholder for the restore backup text field"
        )
        static let copyURI = String(
            localized: "identity_backup.sheet.copy_uri",
            defaultValue: "copy backup",
            comment: "Button that copies the encrypted backup string"
        )
        static let share = String(
            localized: "identity_backup.sheet.share",
            defaultValue: "share",
            comment: "Button that opens the system share sheet for the backup"
        )
        static let copied = String(
            localized: "identity_backup.sheet.copied",
            defaultValue: "copied to clipboard",
            comment: "Status shown after copying the backup string"
        )
        static let fingerprintLabel = String(
            localized: "identity_backup.sheet.fingerprint",
            defaultValue: "fingerprint",
            comment: "Label above the identity fingerprint shown after export/restore"
        )
        static let currentFingerprint = String(
            localized: "identity_backup.sheet.current_fingerprint",
            defaultValue: "this device",
            comment: "Caption above the fingerprint of the live device identity"
        )
        static let scanQR = String(
            localized: "identity_backup.sheet.scan_qr",
            defaultValue: "scan backup qr",
            comment: "Button that opens the camera scanner for an identity backup QR"
        )
        static let hideScanner = String(
            localized: "identity_backup.sheet.hide_scanner",
            defaultValue: "enter backup text",
            comment: "Button that closes the camera scanner and returns to paste field"
        )
        static let restoreConfirmTitle = String(
            localized: "identity_backup.sheet.restore_confirm_title",
            defaultValue: "replace this device's identity?",
            comment: "Title of the confirmation dialog before restoring an identity backup"
        )
        static let restoreConfirmAction = String(
            localized: "identity_backup.sheet.restore_confirm_action",
            defaultValue: "restore and replace",
            comment: "Destructive confirmation button that performs identity restore"
        )
        static let restoreSuccess = String(
            localized: "identity_backup.sheet.restore_success",
            defaultValue: "identity restored. mesh sessions will re-handshake as this fingerprint.",
            comment: "Status shown after a successful identity restore"
        )
        static let exportDoneHint = String(
            localized: "identity_backup.sheet.export_done_hint",
            defaultValue: "write down the passphrase separately from the QR. the backup alone is useless without it — and dangerous with it.",
            comment: "Caption under a successfully created identity backup"
        )
        static let showPassphrase = String(
            localized: "identity_backup.sheet.show_passphrase",
            defaultValue: "show",
            comment: "Toggle label to reveal the passphrase field as plain text"
        )
        static let hidePassphrase = String(
            localized: "identity_backup.sheet.hide_passphrase",
            defaultValue: "hide",
            comment: "Toggle label to mask the passphrase field"
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(palette.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introCard
                    fingerprintCard(
                        title: Strings.currentFingerprint,
                        value: actions.currentFingerprint()
                    )

                    if mode == .export {
                        exportForm
                        if let exportedURI {
                            exportResult(uri: exportedURI)
                        }
                    } else {
                        restoreForm
                        if let restoredFingerprint {
                            fingerprintCard(
                                title: Strings.fingerprintLabel,
                                value: restoredFingerprint
                            )
                            Text(verbatim: Strings.restoreSuccess)
                                .bitchatFont(size: 11)
                                .foregroundColor(accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.alertRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let infoMessage {
                        Text(verbatim: infoMessage)
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
        .themedSheetBackground()
        .confirmationDialog(
            Strings.restoreConfirmTitle,
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button(Strings.restoreConfirmAction, role: .destructive) {
                performRestore()
            }
            Button("common.cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text(verbatim: mode == .export ? Strings.exportTitle : Strings.restoreTitle)
                .bitchatFont(size: 14, weight: .bold)
                .foregroundColor(accent)
            Spacer()
            SheetCloseButton {
                isPresented = false
                dismiss()
            }
            .foregroundColor(accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var introCard: some View {
        Text(verbatim: mode == .export ? Strings.exportIntro : Strings.restoreIntro)
            .bitchatFont(size: 11)
            .foregroundColor(secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(boxColor)
            .cornerRadius(8)
    }

    private func fingerprintCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .bitchatFont(size: 10, weight: .semibold)
                .foregroundColor(secondaryText)
            Text(verbatim: formatFingerprint(value))
                .bitchatFont(size: 12, weight: .medium)
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(boxColor)
        .cornerRadius(8)
    }

    private var exportForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            passphraseFields(includeConfirm: true)

            Button(action: createBackup) {
                Text(verbatim: Strings.createBackup)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(accent.opacity(0.12))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || passphrase.isEmpty || confirmPassphrase.isEmpty)
        }
    }

    private var restoreForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            if showScanner {
                IdentityBackupScanner { code in
                    backupText = code
                    showScanner = false
                    infoMessage = nil
                    errorMessage = nil
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: { showScanner = false }) {
                    Text(verbatim: Strings.hideScanner)
                        .bitchatFont(size: 12)
                        .foregroundColor(secondaryText)
                }
                .buttonStyle(.plain)
            } else {
                backupTextEditor
                Button(action: { showScanner = true }) {
                    Label(Strings.scanQR, systemImage: "camera.viewfinder")
                        .bitchatFont(size: 12)
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }
            #else
            backupTextEditor
            #endif

            passphraseFields(includeConfirm: false)

            Button(action: { showRestoreConfirm = true }) {
                Text(verbatim: Strings.restoreAction)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(palette.alertRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || passphrase.isEmpty || backupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var backupTextEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $backupText)
                .frame(minHeight: 88)
                .bitchatFont(size: 11)
                .padding(8)
                .background(boxColor)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.secondary.opacity(0.25), lineWidth: 1)
                )
            if backupText.isEmpty {
                Text(verbatim: Strings.backupPlaceholder)
                    .bitchatFont(size: 10)
                    .foregroundColor(secondaryText.opacity(0.7))
            }
        }
    }

    private func passphraseFields(includeConfirm: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: Strings.passphrase)
                    .bitchatFont(size: 11, weight: .semibold)
                    .foregroundColor(textColor)
                Spacer()
                Button(revealPassphrase ? Strings.hidePassphrase : Strings.showPassphrase) {
                    revealPassphrase.toggle()
                }
                .buttonStyle(.plain)
                .bitchatFont(size: 10)
                .foregroundColor(secondaryText)

                if mode == .export {
                    Button(Strings.suggest) {
                        let suggested = IdentityBackupService.suggestPassphrase()
                        passphrase = suggested
                        confirmPassphrase = suggested
                        revealPassphrase = true
                    }
                    .buttonStyle(.plain)
                    .bitchatFont(size: 10, weight: .semibold)
                    .foregroundColor(accent)
                }
            }

            secureField($passphrase)

            if includeConfirm {
                Text(verbatim: Strings.confirmPassphrase)
                    .bitchatFont(size: 11, weight: .semibold)
                    .foregroundColor(textColor)
                secureField($confirmPassphrase)
            }
        }
        .padding(12)
        .background(boxColor)
        .cornerRadius(8)
    }

    @ViewBuilder
    private func secureField(_ binding: Binding<String>) -> some View {
        Group {
            if revealPassphrase {
                TextField("", text: binding)
            } else {
                SecureField("", text: binding)
            }
        }
        .textFieldStyle(.plain)
        .bitchatFont(size: 12)
        .foregroundColor(textColor)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(palette.secondary.opacity(0.08))
        .cornerRadius(6)
        .autocorrectionDisabled(true)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    private func exportResult(uri: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let exportedFingerprint {
                fingerprintCard(title: Strings.fingerprintLabel, value: exportedFingerprint)
            }

            QRCodeImage(data: uri, size: 220)
                .frame(maxWidth: .infinity)

            Text(verbatim: compactToken ?? uri)
                .bitchatFont(size: 10)
                .foregroundColor(secondaryText)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(boxColor)
                .cornerRadius(8)

            HStack(spacing: 10) {
                Button(action: { copyToClipboard(compactToken ?? uri) }) {
                    Text(verbatim: Strings.copyURI)
                        .bitchatFont(size: 12, weight: .semibold)
                        .foregroundColor(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(accent.opacity(0.12))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                ShareLink(item: compactToken ?? uri) {
                    Text(verbatim: Strings.share)
                        .bitchatFont(size: 12, weight: .semibold)
                        .foregroundColor(textColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(boxColor)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Text(verbatim: Strings.exportDoneHint)
                .bitchatFont(size: 11)
                .foregroundColor(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(boxColor.opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Actions

    private func createBackup() {
        errorMessage = nil
        infoMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let uri = try actions.exportBackup(passphrase, confirmPassphrase)
            exportedURI = uri
            compactToken = try? IdentityBackupService.compactToken(fromURI: uri)
            exportedFingerprint = actions.currentFingerprint()
            // Clear passphrase fields after success so screenshots are less risky.
            passphrase = ""
            confirmPassphrase = ""
            revealPassphrase = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            exportedURI = nil
            compactToken = nil
            exportedFingerprint = nil
        }
    }

    private func performRestore() {
        errorMessage = nil
        infoMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let fingerprint = try actions.restoreBackup(backupText, passphrase)
            restoredFingerprint = fingerprint
            passphrase = ""
            revealPassphrase = false
            infoMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            restoredFingerprint = nil
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
        infoMessage = Strings.copied
    }

    private func formatFingerprint(_ hex: String) -> String {
        let clean = hex.lowercased().filter(\.isHexDigit)
        guard !clean.isEmpty else { return hex }
        var groups: [String] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let end = clean.index(index, offsetBy: 4, limitedBy: clean.endIndex) ?? clean.endIndex
            groups.append(String(clean[index..<end]))
            index = end
        }
        return groups.joined(separator: " ")
    }
}

#if os(iOS)
/// Camera scanner that returns any QR payload string (identity backup URI/token).
private struct IdentityBackupScanner: View {
    var onCode: (String) -> Void
    @State private var lastCode = ""

    var body: some View {
        CameraScannerView(isActive: true) { code in
            guard code != lastCode else { return }
            lastCode = code
            onCode(code)
        }
    }
}
#endif
