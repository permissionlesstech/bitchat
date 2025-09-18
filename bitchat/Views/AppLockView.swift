import SwiftUI
#if os(iOS)
import UIKit
#endif

struct AppLockView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.colorScheme) var colorScheme
    @State private var pinInput: String = ""
    @State private var authError: String? = nil
    @State private var now: Date = Date()
    @State private var lastWait: TimeInterval = 0

    private var textColor: Color { colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0) }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.9 : 0.92).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("bitchat")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)

                switch appLock.method {
                case .deviceAuth:
                    if appLock.deviceAuthAvailable() {
                        Button("Unlock") { appLock.unlockWithDeviceAuth() }
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.blue)
                            .buttonStyle(.plain)
                    } else if appLock.hasPINConfigured() {
                        // Fallback to PIN entry when device auth is unavailable
                        VStack(spacing: 8) {
                            Text("device authentication unavailable — use your PIN")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.orange)
                            SecureField("Enter PIN", text: $pinInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                            HStack(spacing: 12) {
                                Button("Unlock") {
                                    let ok = appLock.validate(pin: pinInput)
                                    if !ok { authError = "Incorrect PIN"; pinInput = "" }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Text("device authentication unavailable")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.orange)
                            Button("Use Device") { appLock.unlockWithDeviceAuth() }
                                .buttonStyle(.plain)
                                .foregroundColor(.gray)
                                .disabled(true)
                        }
                    }
                case .pin:
                    VStack(spacing: 8) {
                        SecureField("Enter PIN", text: $pinInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        let wait = appLock.backoffRemaining(now: now)
                        if wait > 0 {
                            Text("too many attempts — try again in \(formatWait(wait))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.orange)
                                #if os(iOS)
                                .accessibilityLabel("Too many attempts. Try again in \(formatWait(wait))")
                                #endif
                        }
                        HStack(spacing: 12) {
                            Button("Unlock") {
                                let ok = appLock.validate(pin: pinInput)
                                if !ok {
                                    if appLock.backoffRemaining(now: Date()) > 0 { authError = nil } else { authError = "Incorrect PIN" }
                                    pinInput = ""
                                    let newWait = appLock.backoffRemaining(now: Date())
                                    if newWait > 0 && lastWait == 0 {
                                        #if os(iOS)
                                        let gen = UINotificationFeedbackGenerator()
                                        gen.notificationOccurred(.warning)
                                        UIAccessibility.post(notification: .announcement, argument: "Too many attempts. Try again in \(formatWait(newWait))")
                                        #endif
                                        lastWait = newWait
                                    }
                                }
                            }
                            .disabled(wait > 0)
                            .buttonStyle(.plain)
                            .foregroundColor(wait > 0 ? .gray : .blue)
                            Button(appLock.biometryType() == .faceID ? "Use Face ID" : (appLock.biometryType() == .touchID ? "Use Touch ID" : "Use Device")) { appLock.unlockWithDeviceAuth() }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                                .accessibilityLabel(appLock.biometryType() == .faceID ? "Use Face ID to unlock" : (appLock.biometryType() == .touchID ? "Use Touch ID to unlock" : "Use device authentication to unlock"))
                        }
                    }
                    .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                        now = Date()
                        let w = appLock.backoffRemaining(now: now)
                        if w == 0 { lastWait = 0 }
                    }
                case .off:
                    EmptyView()
                }

                if let err = authError {
                    Text(err)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
            .padding()
        }
        .accessibilityIdentifier("AppLockView")
    }
}

private func formatWait(_ seconds: TimeInterval) -> String {
    let s = Int(ceil(seconds))
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}
