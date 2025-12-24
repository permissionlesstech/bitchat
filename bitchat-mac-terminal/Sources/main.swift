#!/usr/bin/env swift

import Foundation
import CoreImage

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Pairing Server

class PairingServer: NSObject, NetServiceDelegate, StreamDelegate {
    private var netService: NetService?
    private var serverSocket: CFSocket?
    private var socketSource: CFRunLoopSource?
    private var peerID: String
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    init(peerID: String) {
        self.peerID = peerID
        super.init()
    }

    func updatePeerID(_ newPeerID: String) {
        self.peerID = newPeerID
        // Restart service with new peer ID
        netService?.stop()
        if let port = getCurrentPort() {
            publishService(port: port)
        }
    }

    func start() -> Bool {
        // Create TCP socket
        guard let socket = createServerSocket() else {
            print("Failed to create server socket")
            return false
        }

        self.serverSocket = socket

        // Get the port number
        guard let port = getSocketPort(socket) else {
            print("Failed to get socket port")
            return false
        }

        print("TCP server listening on port \(port)")

        // Publish Bonjour service
        publishService(port: port)

        return true
    }

    private func createServerSocket() -> CFSocket? {
        var context = CFSocketContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let socket = CFSocketCreate(
            kCFAllocatorDefault,
            PF_INET,
            SOCK_STREAM,
            IPPROTO_TCP,
            CFSocketCallBackType.acceptCallBack.rawValue,
            { (socket, callbackType, address, data, info) in
                guard let info = info else { return }
                let server = Unmanaged<PairingServer>.fromOpaque(info).takeUnretainedValue()
                server.handleConnection(socket: socket, address: address, data: data)
            },
            &context
        )

        guard let socket = socket else { return nil }

        // Set socket options
        var yes = 1
        setsockopt(CFSocketGetNative(socket), SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int>.size))

        // Bind to any available port
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Random port
        addr.sin_addr.s_addr = INADDR_ANY

        let addressData = withUnsafePointer(to: &addr) {
            Data(bytes: $0, count: MemoryLayout<sockaddr_in>.size)
        }

        let result = CFSocketSetAddress(socket, addressData as CFData)
        if result != .success {
            return nil
        }

        // Add to run loop
        socketSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), socketSource, .commonModes)

        return socket
    }

    private func getSocketPort(_ socket: CFSocket) -> Int? {
        guard let addressData = CFSocketCopyAddress(socket) as Data? else { return nil }

        return addressData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int? in
            guard let addr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr_in.self) else {
                return nil
            }
            return Int(UInt16(bigEndian: addr.pointee.sin_port))
        }
    }

    private func getCurrentPort() -> Int? {
        guard let socket = serverSocket else { return nil }
        return getSocketPort(socket)
    }

    private func publishService(port: Int) {
        // Create TXT record with peer ID
        let txtData = NetService.data(fromTXTRecord: [
            "peerID": peerID.data(using: .utf8) ?? Data()
        ])

        netService = NetService(domain: "local.", type: "_bitchat._tcp.", name: "", port: Int32(port))
        netService?.setTXTRecord(txtData)
        netService?.delegate = self
        netService?.publish()

        print("Publishing Bonjour service: _bitchat._tcp on port \(port)")
    }

    private func handleConnection(socket: CFSocket?, address: CFData?, data: UnsafeRawPointer?) {
        guard let data = data else { return }

        let nativeSocket = data.load(as: CFSocketNativeHandle.self)

        print("\nIncoming connection...")

        // Create streams from socket
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocket, &readStream, &writeStream)

        guard let inputStream = readStream?.takeRetainedValue() as InputStream?,
              let outputStream = writeStream?.takeRetainedValue() as OutputStream? else {
            close(nativeSocket)
            print("Failed to create streams")
            return
        }

        self.inputStream = inputStream
        self.outputStream = outputStream

        inputStream.delegate = self
        outputStream.delegate = self

        inputStream.schedule(in: .current, forMode: .common)
        outputStream.schedule(in: .current, forMode: .common)

        inputStream.open()
        outputStream.open()

        print("Connection established")
        print("Waiting for peer ID validation...")
    }

    // MARK: - StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let inputStream = aStream as? InputStream else { return }
            handleIncomingData(from: inputStream)

        case .hasSpaceAvailable:
            break

        case .errorOccurred:
            print("Stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
            closeStreams()

        case .endEncountered:
            print("Connection closed")
            closeStreams()

        default:
            break
        }
    }

    private func handleIncomingData(from stream: InputStream) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = stream.read(&buffer, maxLength: buffer.count)

        if bytesRead > 0 {
            let data = Data(buffer[..<bytesRead])
            if let message = String(data: data, encoding: .utf8) {
                print("Received: \(message)")

                // Validate expiration first
                if Date() > storedExpirationDate {
                    print("Pairing link has expired!")
                    sendResponse("ERROR:Expired")
                    closeStreams()
                    return
                }

                // Simple validation: check if message contains peer ID
                if message.contains(peerID) {
                    print("Peer ID validated successfully!")
                    sendResponse("OK:\(peerID)")
                } else {
                    print("Peer ID mismatch!")
                    sendResponse("ERROR:Invalid peer ID")
                    closeStreams()
                }
            }
        }
    }

    private func sendResponse(_ message: String) {
        guard let outputStream = outputStream,
              let data = message.data(using: .utf8) else { return }

        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let baseAddress = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            outputStream.write(baseAddress, maxLength: data.count)
        }

        print("Sent: \(message)")
    }

    private func closeStreams() {
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .current, forMode: .common)
        outputStream?.remove(from: .current, forMode: .common)
        inputStream = nil
        outputStream = nil
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        print("Bonjour service published successfully")
        print("Service name: \(sender.name)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("Failed to publish Bonjour service: \(errorDict)")
    }

    func netServiceDidStop(_ sender: NetService) {
        print("Bonjour service stopped")
    }

    deinit {
        netService?.stop()
        if let socketSource = socketSource {
            CFRunLoopSourceInvalidate(socketSource)
        }
        if let serverSocket = serverSocket {
            CFSocketInvalidate(serverSocket)
        }
    }
}

// MARK: - QR Code Generation

func generateQRCode(from string: String) -> String? {
    guard let data = string.data(using: .utf8) else { return nil }

    // Create QR code filter
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")

    guard let outputImage = filter.outputImage else { return nil }

    // Convert to ASCII art
    let scale: CGFloat = 1.0
    let transformedImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    let context = CIContext()
    guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else {
        return nil
    }

    // Convert to ASCII
    let width = Int(transformedImage.extent.width)
    let height = Int(transformedImage.extent.height)

    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    guard let tiffData = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
        return nil
    }

    var ascii = ""
    for y in 0..<height {
        for x in 0..<width {
            if let color = bitmap.colorAt(x: x, y: y) {
                // Check if pixel is dark
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3.0
                ascii += brightness < 0.5 ? "██" : "  "
            }
        }
        ascii += "\n"
    }

    return ascii
}

// MARK: - Pairing Information

// Store expiration timestamp globally for validation
// NOTE: When a connection is received, validate that Date() < storedExpirationDate
// to ensure the pairing link hasn't expired before accepting the connection
var storedExpirationDate: Date = Date()
var pairingServer: PairingServer?

func generateAndDisplayPairing() -> String {
    // Generate peer ID (simplified - use BitChat's actual peer ID in production)
    let peerID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let rawDeviceName = Host.current().localizedName ?? "Mac"
    let deviceName = rawDeviceName
        .trimmingCharacters(in: .whitespaces)
        .prefix(50)
        .isEmpty ? "Mac" : String(rawDeviceName.trimmingCharacters(in: .whitespaces).prefix(50))

    // Generate pairing URL
    let expiresAt = Date().addingTimeInterval(300) // 5 minutes
    storedExpirationDate = expiresAt
    let timestamp = Int(expiresAt.timeIntervalSince1970)
    // Create custom character set that excludes & and = to prevent URL parsing issues
    var allowedCharacters = CharacterSet.urlQueryAllowed
    allowedCharacters.remove(charactersIn: "&=")
    let encodedName = deviceName.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? deviceName
    let pairingURL = "bitchat://pair?peer=\(peerID)&name=\(encodedName)&expires=\(timestamp)"

    print("\n📱 Pairing Information:")
    print("   Device: \(deviceName)")
    print("   Peer ID: \(peerID)")
    print("   Expires: \(expiresAt)")
    print("")

    print("🔗 Pairing URL:")
    print("   \(pairingURL)")
    print("")

    print("📷 Scan this QR code with your iPhone:")
    print("")

    // Generate and display QR code
    if let qrAscii = generateQRCode(from: pairingURL) {
        print(qrAscii)
    } else {
        print("❌ Failed to generate QR code")
        print("   Use this URL instead: \(pairingURL)")
    }

    print("")
    print("⏳ Waiting for pairing... (expires in 5 minutes)")
    print("   Press 'R' to regenerate QR code")
    print("   Press Ctrl+C to exit")
    print("")

    // Update pairing server with new peer ID
    if let server = pairingServer {
        server.updatePeerID(peerID)
    }

    return peerID
}

// MARK: - Main Program

print("""
╔═══════════════════════════════════════╗
║   BitChat Remote Terminal - Mac      ║
║   Terminal Access Server              ║
╚═══════════════════════════════════════╝

""")

// Generate initial pairing information
let initialPeerID = generateAndDisplayPairing()

// Start pairing server
print("\nStarting pairing server...")
pairingServer = PairingServer(peerID: initialPeerID)
if pairingServer?.start() == true {
    print("")
} else {
    print("Failed to start pairing server\n")
}

// MARK: - Signal Handler (SIGINT)

// Set up SIGINT handler for graceful shutdown
signal(SIGINT, SIG_IGN) // Ignore default handler
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    print("\n\n👋 Goodbye! Thanks for using BitChat Remote Terminal.")
    exit(0)
}
sigintSource.resume()

// MARK: - Stdin Handler

// Set up stdin reader for interactive commands
let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
stdinSource.setEventHandler {
    var buffer = [UInt8](repeating: 0, count: 1024)
    let bytesRead = read(STDIN_FILENO, &buffer, buffer.count)

    if bytesRead > 0 {
        let input = String(bytes: buffer[..<bytesRead], encoding: .utf8)?.uppercased() ?? ""

        if input.contains("R") {
            print("\n🔄 Regenerating QR code with new peer ID...\n")
            _ = generateAndDisplayPairing()
        }
    }
}
stdinSource.resume()

// Keep running
RunLoop.main.run()
