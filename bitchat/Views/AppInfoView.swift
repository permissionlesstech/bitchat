import SwiftUI

struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var appLock: AppLockManager
    @State private var showSetPIN: Bool = false
    @State private var pin1: String = ""
    @State private var pin2: String = ""
    @State private var pinError: String? = nil
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    // MARK: - Constants
    private enum Strings {
        static let appName = "bitchat"
        static let tagline = "sidegroupchat"
        
        enum Features {
            static let title = "FEATURES"
            static let offlineComm = ("wifi.slash", "offline communication", "works without internet using Bluetooth low energy")
            static let encryption = ("lock.shield", "end-to-end encryption", "private messages encrypted with noise protocol")
            static let extendedRange = ("antenna.radiowaves.left.and.right", "extended range", "messages relay through peers, going the distance")
            static let mentions = ("at", "mentions", "use @nickname to notify specific people")
            static let favorites = ("star.fill", "favorites", "get notified when your favorite people join")
            static let geohash = ("number", "local channels", "geohash channels to chat with people in nearby regions over decentralized anonymous relays")
        }
        
        enum Privacy {
            static let title = "PRIVACY"
            static let noTracking = ("eye.slash", "no tracking", "no servers, accounts, or data collection")
            static let ephemeral = ("shuffle", "ephemeral identity", "new peer ID generated regularly")
            static let panic = ("hand.raised.fill", "panic mode", "triple-tap logo to instantly clear all data")
        }
        
        enum HowToUse {
            static let title = "HOW TO USE"
            static let instructions = [
                "• set your nickname by tapping it",
                "• tap #mesh to change channels",
                "• tap people icon for sidebar",
                "• tap a peer's name to start a DM",
                "• triple-tap chat to clear",
                "• type / for commands"
            ]
        }
        
        enum Warning {
            static let title = "WARNING"
            static let message = "private message security has not yet been fully audited. do not use for critical situations until this warning disappears."
        }
    }
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("DONE") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .background(backgroundColor.opacity(0.95))
            
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
        }
        .frame(width: 600, height: 700)
        #else
        NavigationView {
            ScrollView {
                infoContent
            }
            .background(backgroundColor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(textColor)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        #endif
    }
    
    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .center, spacing: 8) {
                Text(Strings.appName)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(Strings.tagline)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            
            // Features
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Features.title)
                
                FeatureRow(icon: Strings.Features.offlineComm.0, 
                          title: Strings.Features.offlineComm.1,
                          description: Strings.Features.offlineComm.2)
                
                FeatureRow(icon: Strings.Features.encryption.0,
                          title: Strings.Features.encryption.1,
                          description: Strings.Features.encryption.2)
                
                FeatureRow(icon: Strings.Features.extendedRange.0,
                          title: Strings.Features.extendedRange.1,
                          description: Strings.Features.extendedRange.2)
                
                FeatureRow(icon: Strings.Features.favorites.0,
                          title: Strings.Features.favorites.1,
                          description: Strings.Features.favorites.2)
                
                FeatureRow(icon: Strings.Features.geohash.0,
                          title: Strings.Features.geohash.1,
                          description: Strings.Features.geohash.2)
                
                FeatureRow(icon: Strings.Features.mentions.0,
                          title: Strings.Features.mentions.1,
                          description: Strings.Features.mentions.2)
            }
            
            // Privacy
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.Privacy.title)
                
                FeatureRow(icon: Strings.Privacy.noTracking.0,
                          title: Strings.Privacy.noTracking.1,
                          description: Strings.Privacy.noTracking.2)
                
                FeatureRow(icon: Strings.Privacy.ephemeral.0,
                          title: Strings.Privacy.ephemeral.1,
                          description: Strings.Privacy.ephemeral.2)
                
                FeatureRow(icon: Strings.Privacy.panic.0,
                          title: Strings.Privacy.panic.1,
                          description: Strings.Privacy.panic.2)
            }

            // App Lock
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("APP LOCK")

                // Enable
                Toggle("require unlock", isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { appLock.setEnabled($0) }
                ))
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)

                if appLock.isEnabled {
                    // Method
                    HStack {
                        Text("method")
                        Spacer()
                        Picker("method", selection: Binding(
                            get: { appLock.method },
                            set: { appLock.setMethod($0) }
                        )) {
                            Text("device").tag(AppLockManager.Method.deviceAuth)
                            Text("pin").tag(AppLockManager.Method.pin)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(textColor)

                    // Grace period
                    HStack {
                        Text("grace")
                        Spacer()
                        Picker("grace", selection: Binding(
                            get: { appLock.gracePeriodSeconds },
                            set: { appLock.setGrace($0) }
                        )) {
                            Text("off").tag(0)
                            Text("15s").tag(15)
                            Text("30s").tag(30)
                            Text("1m").tag(60)
                            Text("5m").tag(300)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(textColor)

                    Toggle("lock on launch", isOn: Binding(
                        get: { appLock.lockOnLaunch },
                        set: { appLock.setLockOnLaunch($0) }
                    ))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(textColor)

                    if appLock.method == .pin {
                        HStack(spacing: 16) {
                            Button("set pin") { showSetPIN = true }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                            Button("clear pin") { appLock.clearPIN() }
                                .buttonStyle(.plain)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .sheet(isPresented: $showSetPIN) {
                VStack(spacing: 12) {
                    HStack {
                        Text("set pin").font(.system(size: 16, weight: .bold, design: .monospaced))
                        Spacer()
                        Button("done") { showSetPIN = false }
                            .buttonStyle(.plain)
                    }
                    SecureField("enter pin", text: $pin1)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    SecureField("confirm pin", text: $pin2)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    if let err = pinError {
                        Text(err).foregroundColor(.red).font(.system(size: 12, design: .monospaced))
                    }
                    Button("save") {
                        // Basic PIN strength and validity checks
                        if pin1.count < 4 || pin1.count > 8 { pinError = "pin must be 4–8 digits"; return }
                        // digits only
                        if !pin1.allSatisfy({ $0.isNumber }) { pinError = "pin must contain only digits"; return }
                        // all same digits
                        if let f = pin1.first, pin1 == String(repeating: f, count: pin1.count) {
                            pinError = "pin cannot be all same digits"; return
                        }
                        // common bad pins
                        let badPins: Set<String> = ["1234","4321","0000","1111","2222","9999","1212","1122"]
                        if badPins.contains(pin1) { pinError = "pin is too common"; return }
                        guard pin1 == pin2 else { pinError = "pins do not match"; return }

                        if appLock.setPIN(pin1) {
                            pin1 = ""; pin2 = ""; pinError = nil
                            showSetPIN = false
                        } else {
                            pinError = "failed to save pin"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            
            // How to Use
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(Strings.HowToUse.title)
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Strings.HowToUse.instructions, id: \.self) { instruction in
                        Text(instruction)
                    }
                }
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(textColor)
            }
            
            // Warning
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(Strings.Warning.title)
                    .foregroundColor(Color.red)
                
                Text(Strings.Warning.message)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            .padding(.bottom, 16)
            .padding(.horizontal)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
            
            .padding(.top)
        }
        .padding()
    }
}

struct SectionHeader: View {
    let title: String
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    init(_ title: String) {
        self.title = title
    }
    
    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(textColor)
            .padding(.top, 8)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                Text(description)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
    }
}

#Preview {
    AppInfoView()
}
