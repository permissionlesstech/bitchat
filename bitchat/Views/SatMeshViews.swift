//
// SatMeshViews.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import CoreLocation

// MARK: - Emergency Panel View

struct EmergencyPanelView: View {
    @ObservedObject var satMeshViewModel: SatMeshViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Emergency Status
                emergencyStatusSection
                
                // SOS Button
                sosButton
                
                // Emergency Message Form
                emergencyMessageForm
                
                // Active Emergencies
                activeEmergenciesSection
                
                Spacer()
            }
            .padding()
            .navigationTitle("Emergency")
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
    
    private var emergencyStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Emergency System")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(satMeshViewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
            }
            
            Text("Satellite connection: \(satMeshViewModel.isConnected ? "Connected" : "Disconnected")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var sosButton: some View {
        Button(action: {
            satMeshViewModel.sendSOS()
        }) {
            HStack {
                Image(systemName: "sos")
                    .font(.title2)
                Text("SEND SOS")
                    .font(.headline)
                    .fontWeight(.bold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.red)
            .cornerRadius(10)
        }
        .disabled(satMeshViewModel.isSendingEmergency || !satMeshViewModel.isConnected)
        .overlay(
            Group {
                if satMeshViewModel.isSendingEmergency {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            }
        )
    }
    
    private var emergencyMessageForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Send Emergency Message")
                .font(.headline)
            
            // Emergency Type Picker
            Picker("Emergency Type", selection: $satMeshViewModel.selectedEmergencyType) {
                ForEach(EmergencyType.allCases, id: \.self) { type in
                    HStack {
                        Text(type.icon)
                        Text(type.displayName)
                    }
                    .tag(type)
                }
            }
            .pickerStyle(MenuPickerStyle())
            
            // Message Text Field
            TextField("Emergency message...", text: $satMeshViewModel.emergencyMessage, axis: .vertical)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .lineLimit(3...6)
            
            // Location Toggle
            Toggle("Include location", isOn: $satMeshViewModel.includeLocation)
            
            // Send Button
            Button(action: {
                satMeshViewModel.sendEmergencyMessage()
            }) {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Send Emergency")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .cornerRadius(10)
            }
            .disabled(satMeshViewModel.emergencyMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || satMeshViewModel.isSendingEmergency || !satMeshViewModel.isConnected)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var activeEmergenciesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Emergencies")
                .font(.headline)
            
            if satMeshViewModel.activeEmergencies.isEmpty {
                Text("No active emergencies")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(satMeshViewModel.activeEmergencies) { emergency in
                    EmergencyRowView(emergency: emergency)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - Emergency Row View

struct EmergencyRowView: View {
    let emergency: EmergencyMessage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(emergency.emergencyType.icon)
                Text(emergency.emergencyType.displayName)
                    .font(.headline)
                Spacer()
                Text(emergency.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(emergency.content)
                .font(.body)
            
            HStack {
                Text("From: \(emergency.senderNickname)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let location = emergency.location {
                    Text("📍 Location")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color.red.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Satellite Status View

struct SatelliteStatusView: View {
    @ObservedObject var satMeshViewModel: SatMeshViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection Status
                    connectionStatusSection
                    
                    // Statistics
                    statisticsSection
                    
                    // Queue Status
                    queueStatusSection
                    
                    // Network Topology
                    networkTopologySection
                    
                    // Actions
                    actionsSection
                }
                .padding()
            }
            .navigationTitle("Satellite Status")
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
    
    private var connectionStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "satellite.fill")
                    .foregroundColor(satMeshViewModel.getStatusColor())
                Text("Satellite Connection")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(satMeshViewModel.getStatusColor())
                    .frame(width: 12, height: 12)
            }
            
            Text(satMeshViewModel.getStatusText())
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if satMeshViewModel.isConnected {
                Text("Connected to satellite network")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("Disconnected from satellite network")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Statistics")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                StatCard(title: "Messages Sent", value: "\(satMeshViewModel.routingStats.totalMessagesRouted)")
                StatCard(title: "Success Rate", value: "\(Int(satMeshViewModel.routingStats.successfulDeliveries > 0 ? Double(satMeshViewModel.routingStats.successfulDeliveries) / Double(satMeshViewModel.routingStats.totalMessagesRouted) * 100 : 0))%")
                StatCard(title: "Bytes Saved", value: satMeshViewModel.formatBytes(satMeshViewModel.bandwidthStats.totalBytesSaved))
                StatCard(title: "Total Cost", value: satMeshViewModel.formatCost(satMeshViewModel.bandwidthStats.totalCost))
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var queueStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Message Queue")
                .font(.headline)
            
            Text(satMeshViewModel.formatQueueStatus())
                .font(.subheadline)
            
            VStack(spacing: 5) {
                QueueRow(priority: "Emergency", count: satMeshViewModel.queueStatus.emergency, color: .red)
                QueueRow(priority: "High", count: satMeshViewModel.queueStatus.high, color: .orange)
                QueueRow(priority: "Normal", count: satMeshViewModel.queueStatus.normal, color: .blue)
                QueueRow(priority: "Low", count: satMeshViewModel.queueStatus.low, color: .gray)
                QueueRow(priority: "Background", count: satMeshViewModel.queueStatus.background, color: .secondary)
            }
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var networkTopologySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Network Topology")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    satMeshViewModel.refreshNetworkTopology()
                }
                .font(.caption)
            }
            
            Text("\(satMeshViewModel.networkTopology.count) nodes connected")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if !satMeshViewModel.networkTopology.isEmpty {
                ForEach(satMeshViewModel.networkTopology.prefix(5), id: \.nodeID) { node in
                    NetworkNodeRow(node: node)
                }
            } else {
                Text("No network nodes detected")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding()
        .background(Color.purple.opacity(0.1))
        .cornerRadius(10)
    }
    
    private var actionsSection: some View {
        VStack(spacing: 10) {
            Button("Restart Services") {
                satMeshViewModel.restartServices()
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .cornerRadius(10)
            
            Button("Clear All Data") {
                satMeshViewModel.clearAllData()
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.red)
            .cornerRadius(10)
        }
    }
}

// MARK: - Global Chat View

struct GlobalChatView: View {
    @ObservedObject var satMeshViewModel: SatMeshViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(satMeshViewModel.globalMessages) { message in
                                GlobalMessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: satMeshViewModel.globalMessages.count) { _ in
                        if let lastMessage = satMeshViewModel.globalMessages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Message Input
                messageInputSection
            }
            .navigationTitle("Global Chat")
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
    
    private var messageInputSection: some View {
        VStack(spacing: 10) {
            // Priority Picker
            Picker("Priority", selection: $satMeshViewModel.globalMessagePriority) {
                Text("Normal").tag(UInt8(1))
                Text("High").tag(UInt8(2))
                Text("Emergency").tag(UInt8(3))
            }
            .pickerStyle(SegmentedPickerStyle())
            
            // Message Input
            HStack {
                TextField("Global message...", text: $satMeshViewModel.globalMessageText, axis: .vertical)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .lineLimit(1...3)
                
                Button(action: {
                    satMeshViewModel.sendGlobalMessage()
                }) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                        .padding(8)
                        .background(satMeshViewModel.globalMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(8)
                }
                .disabled(satMeshViewModel.globalMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || satMeshViewModel.isSendingGlobal || !satMeshViewModel.isConnected)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
    }
}

// MARK: - Global Message Row

struct GlobalMessageRow: View {
    let message: BitchatMessage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("🌍")
                Text(message.sender)
                    .font(.headline)
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(message.content)
                .font(.body)
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - Configuration View

struct SatMeshConfigurationView: View {
    @ObservedObject var satMeshViewModel: SatMeshViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                // Satellite Settings
                Section("Satellite Settings") {
                    Toggle("Enable Satellite Messaging", isOn: $satMeshViewModel.config.enableSatellite)
                    Toggle("Enable Emergency Broadcast", isOn: $satMeshViewModel.config.enableEmergencyBroadcast)
                    Toggle("Enable Global Routing", isOn: $satMeshViewModel.config.enableGlobalRouting)
                }
                
                // Performance Settings
                Section("Performance Settings") {
                    HStack {
                        Text("Max Message Size")
                        Spacer()
                        Text("\(satMeshViewModel.config.maxMessageSize) bytes")
                    }
                    
                    Toggle("Enable Compression", isOn: $satMeshViewModel.config.compressionEnabled)
                    
                    HStack {
                        Text("Cost Limit")
                        Spacer()
                        Text(satMeshViewModel.formatCost(satMeshViewModel.config.costLimit))
                    }
                }
                
                // Satellite Selection
                Section("Satellite Selection") {
                    Picker("Preferred Satellite", selection: $satMeshViewModel.config.preferredSatellite) {
                        Text("Iridium").tag("iridium")
                        Text("Starlink").tag("starlink")
                        Text("Globalstar").tag("globalstar")
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                // Actions
                Section {
                    Button("Update Configuration") {
                        satMeshViewModel.updateConfiguration()
                    }
                    .foregroundColor(.blue)
                    
                    Button("Reset to Defaults") {
                        satMeshViewModel.resetConfiguration()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("SatMesh Configuration")
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

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.white)
        .cornerRadius(8)
        .shadow(radius: 1)
    }
}

struct QueueRow: View {
    let priority: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(priority)
                .font(.caption)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .fontWeight(.semibold)
        }
    }
}

struct NetworkNodeRow: View {
    let node: NetworkNode
    
    var body: some View {
        HStack {
            Image(systemName: node.isOnline ? "circle.fill" : "circle")
                .foregroundColor(node.isOnline ? .green : .red)
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(node.nodeID.prefix(8))
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(node.nodeType.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if let batteryLevel = node.batteryLevel {
                Text("\(Int(batteryLevel * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SatMesh Button

struct SatMeshButton: View {
    @ObservedObject var satMeshViewModel: SatMeshViewModel
    
    var body: some View {
        Menu {
            Button(action: {
                satMeshViewModel.toggleEmergencyPanel()
            }) {
                Label("Emergency", systemImage: "exclamationmark.triangle.fill")
            }
            
            Button(action: {
                satMeshViewModel.toggleSatellitePanel()
            }) {
                Label("Satellite Status", systemImage: "satellite.fill")
            }
            
            Button(action: {
                satMeshViewModel.toggleGlobalChat()
            }) {
                Label("Global Chat", systemImage: "globe")
            }
            
            Button(action: {
                satMeshViewModel.toggleConfiguration()
            }) {
                Label("Configuration", systemImage: "gear")
            }
        } label: {
            Image(systemName: "satellite.fill")
                .foregroundColor(satMeshViewModel.getStatusColor())
        }
    }
} 