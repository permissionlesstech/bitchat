import SwiftUI

struct AppLockView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.colorScheme) var colorScheme
    @State private var pinInput: String = ""
    @State private var authError: String? = nil

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
                    Button("Unlock") { appLock.unlockWithDeviceAuth() }
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.blue)
                        .buttonStyle(.plain)
                case .pin:
                    VStack(spacing: 8) {
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
                            Button("Use Device") { appLock.unlockWithDeviceAuth() }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                        }
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
