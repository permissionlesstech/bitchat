//
// MeshtasticSettingsView.swift
// BitChat Meshtastic Integration
//
// User interface for configuring Meshtastic integration settings
//

import SwiftUI

struct MeshtasticSettingsView: View {
    @StateObject private var fallbackManager = MeshtasticFallbackManager.shared
    @StateObject private var bridge = MeshtasticBridge.shared
    @State private var showingConsentDialog = false
    @State private var isScanning = false
    @State private var showingDeviceDetails = false
    @State private var selectedDevice: MeshtasticDeviceInfo?
    
    var body: some View {
        NavigationView {
            List {
                // Main Enable/Disable Section
                Section {
                    Toggle("Enable Meshtastic Fallback", isOn: Binding(
                        get: { fallbackManager.isEnabled },
                        set: { enabled in
                            if enabled {
                                Task {
                                    await fallbackManager.enableMeshtasticIntegration()
                                }
                            } else {
                                fallbackManager.disableMeshtasticIntegration()
                            }
                        }
                    ))
                    .disabled(!fallbackManager.userConsented)
                    
                    if !fallbackManager.userConsented {
                        Button("Grant Permission") {
                            showingConsentDialog = true
                        }
                        .foregroundColor(.blue)
                    }
                } header: {
                    Text("Meshtastic Integration")
                } footer: {
                    Text("Automatically fallback to Meshtastic LoRa mesh when no Bluetooth LE hops are available. Requires compatible Meshtastic device.")
                }
                
                // Status Section
                if fallbackManager.userConsented {
                    Section("Status") {
                        HStack {
                            Circle()
                                .fill(fallbackManager.currentStatus.color)
                                .frame(width: 12, height: 12)
                            Text(fallbackManager.currentStatus.displayName)
                            Spacer()
                            if isScanning {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        
                        if let lastAttempt = fallbackManager.lastFallbackAttempt {
                            HStack {
                                Text("Last Fallback")
                                Spacer()
                                Text(lastAttempt, style: .relative)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Text("Success Rate")
                            Spacer()
                            Text("\(Int(fallbackManager.fallbackSuccessRate * 100))%")
                                .foregroundColor(fallbackManager.fallbackSuccessRate > 0.7 ? .green : .orange)
                        }
                    }
                }
                
                // Configuration Section
                if fallbackManager.isEnabled {
                    Section("Configuration") {
                        Toggle("Auto Fallback", isOn: $fallbackManager.autoFallbackEnabled)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Fallback Threshold")
                                Spacer()
                                Text("\(Int(fallbackManager.fallbackThreshold))s")
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(
                                value: $fallbackManager.fallbackThreshold,
                                in: 10...300,
                                step: 5
                            ) {
                                Text("Threshold")
                            }
                        }
                    }
                    
                    // Device Selection Section
                    Section {
                        HStack {
                            Text("Available Devices")
                            Spacer()
                            Button(action: scanDevices) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(isScanning)
                        }
                        
                        if bridge.availableDevices.isEmpty && !isScanning {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No devices found")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ForEach(bridge.availableDevices, id: \.deviceId) { device in
                                DeviceRow(
                                    device: device,
                                    isPreferred: device.deviceId == fallbackManager.preferredDeviceId,
                                    onSelect: { selectDevice(device) },
                                    onShowDetails: { 
                                        selectedDevice = device
                                        showingDeviceDetails = true
                                    }
                                )
                            }
                        }
                    } header: {
                        Text("Meshtastic Devices")
                    } footer: {
                        Text("Select a preferred device for automatic connection. BitChat will attempt to connect to this device first when fallback is needed.")
                    }
                    
                    // Advanced Settings
                    Section("Advanced") {
                        NavigationLink("Network Settings") {
                            MeshtasticNetworkSettingsView()
                        }
                        
                        NavigationLink("Protocol Configuration") {
                            MeshtasticProtocolSettingsView()
                        }
                        
                        Button("Reset to Defaults") {
                            resetToDefaults()
                        }
                        .foregroundColor(.red)
                    }
                }
                
                // Information Section
                Section("About Meshtastic") {
                    Link("Learn More", destination: URL(string: "https://meshtastic.org")!)
                    Link("Hardware Guide", destination: URL(string: "https://meshtastic.org/docs/hardware")!)
                    Link("BitChat Integration Docs", destination: URL(string: "https://github.com/jackjackbits/bitchat")!)
                }
            }
            .navigationTitle("Meshtastic")
            .alert("Meshtastic Permission", isPresented: $showingConsentDialog) {
                Button("Cancel", role: .cancel) { }
                Button("Allow") {
                    Task {
                        await fallbackManager.enableMeshtasticIntegration()
                    }
                }
            } message: {
                Text("BitChat would like to use Meshtastic devices for mesh networking fallback. This allows messaging when Bluetooth LE is unavailable.\n\nNo personal data is transmitted outside your local mesh network.")
            }
            .sheet(isPresented: $showingDeviceDetails) {
                if let device = selectedDevice {
                    MeshtasticDeviceDetailView(device: device)
                }
            }
        }
    }
    
    private func scanDevices() {
        isScanning = true
        Task {
            await bridge.scanDevices()
            isScanning = false
        }
    }
    
    private func selectDevice(_ device: MeshtasticDeviceInfo) {
        fallbackManager.setPreferredDevice(device.deviceId)
        
        // Attempt to connect to the selected device
        Task {
            await bridge.connectToDevice(device.deviceId)
        }
    }
    
    private func resetToDefaults() {
        fallbackManager.setAutoFallback(true)
        fallbackManager.setFallbackThreshold(30.0)
        fallbackManager.setPreferredDevice(nil)
    }
}

struct DeviceRow: View {
    let device: MeshtasticDeviceInfo
    let isPreferred: Bool
    let onSelect: () -> Void
    let onShowDetails: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(device.name)
                        .font(.headline)
                    
                    if isPreferred {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }
                
                Text(device.interfaceType.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if !device.available {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                if let signal = device.signalStrength {
                    HStack(spacing: 2) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                        Text("\(signal) dBm")
                            .font(.caption)
                    }
                    .foregroundColor(signalColor(signal))
                }
                
                if let battery = device.batteryLevel {
                    HStack(spacing: 2) {
                        Image(systemName: batteryIcon(battery))
                            .font(.caption2)
                        Text("\(battery)%")
                            .font(.caption)
                    }
                    .foregroundColor(batteryColor(battery))
                }
            }
            .foregroundColor(.secondary)
            
            Button(action: onShowDetails) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
    
    private func signalColor(_ signal: Int) -> Color {
        if signal > -70 { return .green }
        if signal > -85 { return .orange }
        return .red
    }
    
    private func batteryColor(_ battery: Int) -> Color {
        if battery > 50 { return .green }
        if battery > 20 { return .orange }
        return .red
    }
    
    private func batteryIcon(_ battery: Int) -> String {
        if battery > 75 { return "battery.100" }
        if battery > 50 { return "battery.75" }
        if battery > 25 { return "battery.25" }
        return "battery.0"
    }
}

struct MeshtasticDeviceDetailView: View {
    let device: MeshtasticDeviceInfo
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Device Information") {
                    DetailRow(label: "Name", value: device.name)
                    DetailRow(label: "Device ID", value: device.deviceId)
                    DetailRow(label: "Interface Type", value: device.interfaceType.capitalized)
                    DetailRow(label: "Connection", value: device.connectionString)
                    DetailRow(label: "Status", value: device.available ? "Available" : "Unavailable")
                }
                
                if device.signalStrength != nil || device.batteryLevel != nil {
                    Section("Status") {
                        if let signal = device.signalStrength {
                            DetailRow(label: "Signal Strength", value: "\(signal) dBm")
                        }
                        if let battery = device.batteryLevel {
                            DetailRow(label: "Battery Level", value: "\(battery)%")
                        }
                    }
                }
                
                Section("Actions") {
                    Button("Set as Preferred") {
                        MeshtasticFallbackManager.shared.setPreferredDevice(device.deviceId)
                        dismiss()
                    }
                    
                    Button("Test Connection") {
                        Task {
                            await MeshtasticBridge.shared.connectToDevice(device.deviceId)
                        }
                    }
                }
            }
            .navigationTitle("Device Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

// Placeholder views for advanced settings
struct MeshtasticNetworkSettingsView: View {
    var body: some View {
        List {
            Section("Network Configuration") {
                Text("Channel Settings")
                Text("Encryption Options")
                Text("Routing Preferences")
            }
        }
        .navigationTitle("Network Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MeshtasticProtocolSettingsView: View {
    var body: some View {
        List {
            Section("Protocol Options") {
                Text("Message Fragmentation")
                Text("Retry Policies")
                Text("TTL Settings")
            }
        }
        .navigationTitle("Protocol Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    MeshtasticSettingsView()
}
