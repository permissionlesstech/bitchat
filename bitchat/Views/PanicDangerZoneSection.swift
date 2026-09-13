//
// PanicDangerZoneSection.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// The DANGER ZONE of the settings pane: the confirmed panic-wipe button and
/// the three-way setting for what the logo triple-tap does.
struct PanicDangerZoneSection: View {
    /// Wipes all local data. The button here always confirms first and works
    /// in every gesture mode — it never routes through the gesture setting.
    let onPanicWipe: @MainActor () -> Void

    @ThemedPalette private var palette
    @State private var showPanicConfirmation = false
    @AppStorage(PanicGestureSettings.storageKey) private var panicGestureRawValue = PanicGestureSettings.installDefault.rawValue
    /// A mode change waiting on its confirmation dialog.
    @State private var pendingTransition: GuardedTransition?

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    private var panicGestureMode: PanicGestureMode {
        PanicGestureMode(rawValue: panicGestureRawValue) ?? PanicGestureSettings.installDefault
    }

    /// A mode change that lowers safety in either direction asks first:
    /// arming an instant wipe (one fumbled tap can destroy everything), or
    /// disarming the gesture (an emergency wipe that silently does nothing).
    /// Confirm-first is the safe middle and applies at once.
    enum GuardedTransition: Equatable {
        case arm
        case disarm

        var mode: PanicGestureMode {
            switch self {
            case .arm: return .instant
            case .disarm: return .off
            }
        }
    }

    static func guardedTransition(to mode: PanicGestureMode) -> GuardedTransition? {
        switch mode {
        case .instant: return .arm
        case .off: return .disarm
        case .confirm: return nil
        }
    }

    private func selectPanicGestureMode(_ mode: PanicGestureMode) {
        guard mode != panicGestureMode else { return }
        if let transition = Self.guardedTransition(to: mode) {
            pendingTransition = transition
        } else {
            panicGestureRawValue = mode.rawValue
        }
    }

    private var gestureChips: some View {
        ForEach(PanicGestureMode.allCases) { mode in
            OptionChip(
                Text(verbatim: Strings.gestureMode(mode)),
                isSelected: panicGestureMode == mode
            ) {
                selectPanicGestureMode(mode)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(verbatim: Strings.dangerTitle)

            Button(action: { showPanicConfirmation = true }) {
                Text(Strings.panicButton)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.alertRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                Strings.panicConfirmTitle,
                isPresented: $showPanicConfirmation,
                titleVisibility: .visible
            ) {
                Button(Strings.panicConfirmAction, role: .destructive) {
                    onPanicWipe()
                }
                Button("common.cancel", role: .cancel) {}
            }

            Text(Strings.panicNote)
                .bitchatFont(size: 11)
                .foregroundColor(secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)

            // The gesture is the accident-prone entry point, so its behavior
            // is the user's call — three choices rather than a toggle, because
            // "never wipe from the logo" and "ask me first" are different
            // answers and both were asked for.
            SettingsCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Strings.gestureTitle)
                        .bitchatFont(size: 12, weight: .semibold)
                        .foregroundColor(textColor)
                    Text(verbatim: Strings.gestureSubtitle)
                        .bitchatFont(size: 11)
                        .foregroundColor(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Three chips must never clip: side by side when they fit,
                // stacked at accessibility text sizes or in long locales.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { gestureChips }
                    VStack(alignment: .leading, spacing: 8) { gestureChips }
                }

                Text(verbatim: Strings.gestureResetNote)
                    .bitchatFont(size: 11)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .confirmationDialog(
                Text(verbatim: pendingTransition.map(Strings.transitionTitle) ?? ""),
                isPresented: Binding(
                    get: { pendingTransition != nil },
                    set: { if !$0 { pendingTransition = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingTransition
            ) { transition in
                Button(Strings.transitionAction(transition), role: .destructive) {
                    panicGestureRawValue = transition.mode.rawValue
                }
                Button("common.cancel", role: .cancel) {}
            } message: { transition in
                Text(verbatim: Strings.transitionMessage(transition))
            }
        }
    }

    // MARK: - Strings

    private enum Strings {
        static let dangerTitle = String(localized: "app_info.settings.danger.title", defaultValue: "DANGER ZONE", comment: "Section header (uppercase) for destructive actions in settings")
        static let panicButton = String(localized: "app_info.settings.danger.panic_button", defaultValue: "panic wipe", comment: "Button in the settings danger zone that erases all local data after confirmation")
        static let panicNote = String(localized: "app_info.settings.danger.panic_note", defaultValue: "erases all messages, keys, and identity. there is no undo.", comment: "Caption under the panic wipe button explaining what it does")
        static let panicConfirmTitle = String(localized: "app_info.settings.danger.panic_confirm_title", defaultValue: "wipe all data?", comment: "Title of the confirmation dialog before a panic wipe")
        static let panicConfirmAction = String(localized: "app_info.settings.danger.panic_confirm_action", defaultValue: "wipe everything", comment: "Destructive confirmation button that performs the panic wipe")

        static let gestureTitle = String(localized: "app_info.settings.danger.gesture_title", defaultValue: "triple-tap the logo", comment: "Title of the setting controlling what a triple-tap on the bitchat/ logo does")
        static let gestureSubtitle = String(localized: "app_info.settings.danger.gesture_subtitle", defaultValue: "the bitchat/ logo can run the same wipe when tapped three times. fast when seconds matter, and easy to set off by accident \u{2014} choose which it is. the button above always asks first.", comment: "Subtitle explaining the triple-tap wipe shortcut and why its behavior can be configured")
        static let gestureResetNote = String(localized: "app_info.settings.danger.gesture_reset_note", defaultValue: "a wipe resets this to instant, so a device you just wiped is ready to wipe again.", comment: "Caption explaining that performing a panic wipe sets the triple-tap gesture back to instant")
        static func gestureMode(_ mode: PanicGestureMode) -> String {
            switch mode {
            case .instant:
                return String(localized: "app_info.settings.danger.gesture_instant", defaultValue: "instantly", comment: "Option: a triple-tap on the bitchat/ logo wipes all data immediately, with no confirmation")
            case .confirm:
                return String(localized: "app_info.settings.danger.gesture_confirm", defaultValue: "ask first", comment: "Option: a triple-tap on the bitchat/ logo asks for confirmation before wiping all data")
            case .off:
                return String(localized: "app_info.settings.danger.gesture_off", defaultValue: "off", comment: "Option: a triple-tap on the bitchat/ logo does nothing; only the settings button can wipe")
            }
        }
        static func transitionTitle(_ transition: GuardedTransition) -> String {
            switch transition {
            case .arm:
                return String(localized: "app_info.settings.danger.gesture_arm_title", defaultValue: "wipe instantly from the logo?", comment: "Title of the dialog confirming that the triple-tap panic gesture should wipe instantly, with no confirmation")
            case .disarm:
                return String(localized: "app_info.settings.danger.gesture_disable_title", defaultValue: "turn off the logo wipe?", comment: "Title of the dialog confirming that the triple-tap panic gesture should be disabled")
            }
        }
        static func transitionAction(_ transition: GuardedTransition) -> String {
            switch transition {
            case .arm:
                return String(localized: "app_info.settings.danger.gesture_arm_action", defaultValue: "make it instant", comment: "Confirmation button that sets the triple-tap panic gesture to wipe instantly")
            case .disarm:
                return String(localized: "app_info.settings.danger.gesture_disable_action", defaultValue: "turn it off", comment: "Confirmation button that disables the triple-tap panic gesture")
            }
        }
        static func transitionMessage(_ transition: GuardedTransition) -> String {
            switch transition {
            case .arm:
                return String(localized: "app_info.settings.danger.gesture_arm_message", defaultValue: "the third tap will wipe everything, with no dialog. a fumbled tap on the logo can destroy this device's identity and messages.", comment: "Message of the dialog confirming that the triple-tap panic gesture should wipe instantly, warning that a fumbled tap can destroy everything")
            case .disarm:
                return String(localized: "app_info.settings.danger.gesture_disable_message", defaultValue: "the logo will stop wiping entirely. the panic wipe button above still works.", comment: "Message of the dialog confirming that the triple-tap panic gesture should be disabled")
            }
        }
    }
}
