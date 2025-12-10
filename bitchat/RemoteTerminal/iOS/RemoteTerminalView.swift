//
// RemoteTerminalView.swift
// Remote Terminal - iOS Side
//
// Terminal UI for iPhone
//

#if os(iOS)
import SwiftUI

struct RemoteTerminalView: View {
    @StateObject private var viewModel = RemoteTerminalViewModel()
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @Binding var showQRScanner: Bool
    @EnvironmentObject var chatViewModel: ChatViewModel
    @State private var showQRScannerInternal = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()
                .background(terminalGreen)

            // Output area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.outputLines) { line in
                            terminalLine(line)
                                .id(line.id)
                        }

                        // Auto-scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(terminalBackground)
                .onChange(of: viewModel.outputLines.count) { _ in
                    // Auto-scroll to bottom when new output arrives
                    withAnimation {
                        proxy.scrollTo("bottom")
                    }
                }
            }

            Divider()
                .background(terminalGreen)

            // Input area
            inputView
        }
        .background(terminalBackground)
        .onAppear {
            isInputFocused = true
            // Inject MessageRouter from ChatViewModel
            viewModel.messageRouter = chatViewModel.getMessageRouter()
        }
        .fullScreenCover(isPresented: $showQRScannerInternal) {
            QRCodeScannerView { pairingInfo in
                NSLog("🎯 [PAIRING] QR Scanner callback in RemoteTerminalView!")
                NSLog("🎯 [PAIRING] Device: \(pairingInfo.deviceName)")
                NSLog("🎯 [PAIRING] PeerID: \(pairingInfo.peerID)")

                // Save device to DeviceAuthorizationManager
                let authorizedDevice = AuthorizedDevice(
                    peerID: pairingInfo.peerID,
                    displayName: pairingInfo.deviceName,
                    permissions: [.terminal]
                )
                DeviceAuthorizationManager.shared.authorize(device: authorizedDevice)
                NSLog("💾 [PAIRING] Device saved to DeviceAuthorizationManager")

                // Handle pairing
                viewModel.macPeerID = pairingInfo.peerID
                viewModel.isConnected = true
                viewModel.outputLines.append(TerminalLine(text: "✅ Connected to \(pairingInfo.deviceName)", type: .system))
                viewModel.outputLines.append(TerminalLine(text: "   Peer ID: \(pairingInfo.peerID.prefix(16))...", type: .system))
                viewModel.outputLines.append(TerminalLine(text: "   Device authorized and saved to keychain", type: .system))
                NSLog("📝 [PAIRING] Added output lines to terminal")

                // Dismiss QR scanner
                showQRScannerInternal = false
                NSLog("🎯 [PAIRING] Dismissed QR scanner")
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack {
            // Connection status
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            Text("Terminal")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)

            Spacer()

            // Working directory
            Text(viewModel.workingDirectory)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(terminalGreen.opacity(0.6))

            Spacer()

            // Bluetooth Internet toggle
            Button(action: {
                Task {
                    await viewModel.toggleProxy()
                }
            }) {
                Image(systemName: viewModel.isProxyEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.isProxyEnabled ? Color.green : terminalGreen.opacity(0.5))
            }

            // QR Scanner button
            Button(action: {
                NSLog("🔘 [PAIRING] QR Scanner button tapped")
                showQRScannerInternal = true
            }) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 14))
                    .foregroundColor(terminalGreen)
            }

            // Copy Peer ID button
            if let peerID = viewModel.macPeerID {
                Button(action: {
                    UIPasteboard.general.string = peerID
                    viewModel.outputLines.append(TerminalLine(text: "✓ Peer ID copied to clipboard", type: .system))
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundColor(terminalGreen)
                }
            }

            // Clear button
            Button(action: {
                viewModel.clearTerminal()
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(terminalGreen)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(terminalBackground)
    }

    // MARK: - Terminal Line

    private func terminalLine(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(colorForLineType(line.type))
            .textSelection(.enabled) // Allow text selection
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorForLineType(_ type: TerminalLineType) -> Color {
        switch type {
        case .command:
            return terminalYellow // Commands in yellow
        case .output:
            return terminalGreen // Output in green
        case .error:
            return terminalRed // Errors in red
        case .system:
            return terminalGreen.opacity(0.7) // System messages dimmed
        }
    }

    // MARK: - Input View

    private var inputView: some View {
        HStack(spacing: 8) {
            // Prompt
            Text("$")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(terminalGreen)

            // Text field
            TextField("Enter command", text: $viewModel.currentCommand)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(terminalGreen)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .focused($isInputFocused)
                .onSubmit {
                    viewModel.executeCommand()
                }

            // Loading indicator
            if viewModel.isExecuting {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: terminalGreen))
                    .scaleEffect(0.8)
            }

            // Send button
            Button(action: {
                viewModel.executeCommand()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(viewModel.currentCommand.isEmpty ? terminalGreen.opacity(0.3) : terminalGreen)
            }
            .disabled(viewModel.currentCommand.isEmpty || viewModel.isExecuting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(terminalBackground)
    }

    // MARK: - Colors

    private var terminalBackground: Color {
        Color.black
    }

    private var terminalGreen: Color {
        Color(red: 0, green: 1, blue: 0) // #00FF00
    }

    private var terminalYellow: Color {
        Color(red: 1, green: 1, blue: 0) // #FFFF00
    }

    private var terminalRed: Color {
        Color(red: 1, green: 0, blue: 0) // #FF0000
    }
}

// MARK: - Preview

#if DEBUG
// Preview requires complex initialization - use simulator for testing
#endif

// MARK: - Example Integration
/*

 // In your main app, present the terminal view:

 struct ContentView: View {
     @State private var showTerminal = false

     var body: some View {
         VStack {
             Button("Open Remote Terminal") {
                 showTerminal = true
             }
         }
         .sheet(isPresented: $showTerminal) {
             RemoteTerminalView()
         }
     }
 }

 */

#endif // os(iOS)
