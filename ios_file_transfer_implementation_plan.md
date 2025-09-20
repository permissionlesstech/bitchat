# iOS File Transfer Implementation Plan

## Overview
This document outlines the implementation plan for adding file transfer capabilities to the iOS BitChat app, based on the features implemented in Android PR #440. The goal is to achieve full cross-platform compatibility for file transfer over Bluetooth mesh and Nostr networks while maintaining the same 5MB file size limit.

## Executive Summary

Based on my analysis of Android PR #440 and the current iOS codebase, we need to implement:

1. **BitchatFilePacket TLV format** - Cross-platform binary encoding for files
2. **Voice recording** - M4A format with real-time size monitoring  
3. **Enhanced FileTransferService** - Support for both mesh (BLE) and off-mesh (Nostr) transfers
4. **Transfer progress tracking** - Real-time progress updates with cancellation support
5. **File management utilities** - MIME type detection, thumbnails, and storage
6. **SwiftUI components** - File picker, voice recorder, and media preview interfaces
7. **Error handling** - Comprehensive validation and user-friendly error messages

## Current State Analysis

### What We Have ✅
- Basic `FileTransferService.swift` with unified mesh/Nostr interface
- `NoiseSecurityConstants.maxMessageSize = 5MB` (matches Android limit)
- Existing BLEService and NostrRelayManager infrastructure
- TLV encoding utilities in protocols
- SwiftUI chat interface foundation

### What We Need 🚧
- BitchatFilePacket TLV schema matching Android exactly
- Voice recording with AVAudioRecorder
- Transfer progress management and UI feedback
- File picker and media preview components
- Enhanced error handling and validation
- Cross-platform testing and validation

## Implementation Tasks

### 1. Study Android PR #440 and Audit Current iOS Codebase

**Goal**: Complete understanding of Android implementation and iOS gaps

**Android PR Analysis**:
- **BitchatFilePacket**: Uses TLV encoding with keys: filename(1), filesize(2), mimetype(3), content(4)
- **File size limits**: 5MB enforced at multiple layers
- **Voice recording**: M4A format, real-time amplitude monitoring
- **Transfer progress**: Fragment-level progress tracking with cancellation
- **UI components**: File picker, voice recorder with waveform visualization
- **Error handling**: Comprehensive validation and user feedback

**iOS Current State**:
- Basic FileTransferService with mesh/Nostr routing ✅
- 5MB limit already configured in NoiseSecurityConstants ✅
- Missing: TLV file packet format, voice recording, progress tracking, file picker UI

### 2. Define Cross-Platform TLV Schema in Swift

**Create**: `BitchatFilePacket.swift`

```swift
struct BitchatFilePacket {
    let fileName: String
    let fileSize: UInt64  
    let mimeType: String
    let content: Data
    
    // TLV Keys (matching Android exactly)
    enum TLVKey: UInt8 {
        case fileName = 0x01
        case fileSize = 0x02  
        case mimeType = 0x03
        case content = 0x04
    }
    
    func encode() -> Data?
    static func decode(_ data: Data) -> BitchatFilePacket?
}
```

**Requirements**:
- Exact TLV format compatibility with Android
- Size validation ≤ `NoiseSecurityConstants.maxMessageSize`
- Comprehensive unit tests with Android-generated test vectors
- Error handling for malformed packets

### 3. Add MIME/File Utility Helpers

**Create**: `FileUtils.swift`

```swift
enum FileUtils {
    static func mimeType(for url: URL) -> String
    static func fileSize(for url: URL) -> UInt64?
    static func formatFileSize(_ bytes: UInt64) -> String
    static func saveIncomingFile(_ packet: BitchatFilePacket) -> URL?
    static func generateThumbnail(for imageUrl: URL) -> UIImage?
    static func isFileTypeSupported(_ mimeType: String) -> Bool
}
```

**Features**:
- UTType-based MIME detection
- Human-readable file size formatting
- Secure file storage in app sandbox
- Image thumbnail generation
- File type validation and filtering

### 4. Implement Voice Recording Feature

**Create**: `VoiceRecorder.swift`

```swift
protocol VoiceRecorderDelegate: AnyObject {
    func voiceRecorder(_ recorder: VoiceRecorder, didStartRecording duration: TimeInterval)
    func voiceRecorder(_ recorder: VoiceRecorder, didUpdateProgress duration: TimeInterval, amplitude: Float)
    func voiceRecorder(_ recorder: VoiceRecorder, didFinishRecording url: URL)
    func voiceRecorder(_ recorder: VoiceRecorder, didFailWithError error: Error)
}

class VoiceRecorder {
    weak var delegate: VoiceRecorderDelegate?
    
    func startRecording() -> Bool
    func stopRecording() -> URL?
    func cancelRecording()
    
    private func estimatedFileSize(for duration: TimeInterval) -> UInt64
}
```

**Specifications**:
- **Format**: M4A (AAC), 16kHz mono, matches Android
- **Size monitoring**: Stop recording when approaching 5MB limit
- **Real-time feedback**: Amplitude levels for UI visualization
- **Audio session**: Proper integration with iOS audio policies
- **Background support**: Continue recording during app backgrounding

### 5. Extend FileTransferService for Mesh (BLE) Transfers

**Enhancement**: Existing `FileTransferService.swift`

```swift
extension FileTransferService {
    // Mesh (BLE) transfers
    func sendFile(via mesh: BitchatFilePacket, to peerID: String) -> TransferID
    func cancelTransfer(_ transferID: TransferID) -> Bool
    
    // Progress tracking
    @Published var activeTransfers: [TransferID: TransferProgress] = [:]
}

struct TransferProgress {
    let transferID: TransferID
    let bytesSent: UInt64
    let bytesTotal: UInt64
    let state: TransferState
    let error: FileTransferError?
}

enum TransferState {
    case preparing, sending, receiving, completed, failed, cancelled
}
```

**Implementation Details**:
- **Chunking**: Split large files into BLE MTU-sized chunks
- **Sequencing**: Add sequence numbers to reassemble packets correctly
- **Flow control**: Respect BLE connection bandwidth limits  
- **Resume capability**: Persist partial transfers across app restarts
- **Error recovery**: Retry failed chunks automatically

### 6. Support Off-Mesh (Nostr) Transfers

**Integration**: Enhanced Nostr relay fallback

```swift
extension FileTransferService {
    // Nostr fallback when mesh unavailable
    private func sendViaNostr(_ packet: BitchatFilePacket, to peerID: String) -> TransferID
    private func receiveViaNostr(_ event: NostrEvent) -> BitchatFilePacket?
}
```

**Protocol**:
- **Event type**: Custom kind:1064 for file transfers
- **Encoding**: Base64-encoded BitchatFilePacket in event content
- **Relay selection**: Choose closest relays based on user location
- **Size limits**: Enforce 5MB limit at relay level
- **Encryption**: End-to-end encrypted file contents

### 7. Implement TransferProgressManager

**Create**: `TransferProgressManager.swift`

```swift
class TransferProgressManager: ObservableObject {
    static let shared = TransferProgressManager()
    
    @Published var transfers: [TransferID: TransferProgress] = [:]
    
    func startTransfer(_ id: TransferID, totalBytes: UInt64)
    func updateProgress(_ id: TransferID, bytesSent: UInt64)
    func completeTransfer(_ id: TransferID)
    func failTransfer(_ id: TransferID, error: FileTransferError)
    func cancelTransfer(_ id: TransferID)
}
```

**Features**:
- **Real-time updates**: Combine publishers for UI reactivity
- **Persistence**: Save progress to UserDefaults for app restart recovery
- **Memory efficiency**: Cleanup completed transfers automatically
- **Thread safety**: Concurrent access from BLE and Nostr layers

### 8. UI: File Picker, Recorder, and Previews

**Components to Create**:

**FilePickerSheet.swift**:
```swift
struct FilePickerSheet: View {
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showVoiceRecorder = false
    
    let onFilePicked: (URL) -> Void
}
```

**VoiceRecorderView.swift**:
```swift
struct VoiceRecorderView: View {
    @StateObject private var recorder = VoiceRecorder()
    @State private var isRecording = false
    @State private var amplitude: Float = 0
    
    var body: some View {
        // Waveform visualization
        // Record/Stop button
        // Duration timer
        // Size indicator
    }
}
```

**MediaPreviewView.swift**:
```swift
struct MediaPreviewView: View {
    let message: BitchatMessage
    
    var body: some View {
        switch message.type {
        case .audio: AudioPlayerView(url: message.contentURL)
        case .image: AsyncImage(url: message.contentURL)
        case .file: FileInfoView(url: message.contentURL)
        default: EmptyView()
        }
    }
}
```

**UI Requirements**:
- **File size validation**: Block selection of files >5MB with clear error message
- **Progress indicators**: Show transfer progress for each message
- **Accessibility**: VoiceOver support for all file transfer features
- **Dark mode**: Proper color adaptation
- **Haptic feedback**: Tactile responses for record start/stop

### 9. Error Handling & Validation

**Create**: `FileTransferError.swift`

```swift
enum FileTransferError: LocalizedError {
    case fileTooLarge(actual: UInt64, limit: UInt64)
    case unsupportedFileType(String)
    case networkUnavailable
    case insufficientStorage
    case decodeFailed
    case writeFailed(Error)
    case cancelled
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let actual, let limit):
            return "File too large (\(FileUtils.formatFileSize(actual))). Maximum size is \(FileUtils.formatFileSize(limit))."
        case .unsupportedFileType(let type):
            return "File type '\(type)' is not supported."
        case .networkUnavailable:
            return "No network connection available for file transfer."
        // ... other cases
        }
    }
}
```

**Validation Strategy**:
- **Pre-transfer validation**: Check file size, type, and storage space
- **Runtime monitoring**: Watch for network disconnections and storage issues
- **User feedback**: Toast notifications and progress sheet error states
- **Retry mechanisms**: Automatic retry for transient failures
- **Graceful degradation**: Fall back from mesh to Nostr when necessary

### 10. End-to-End Testing Matrix

**Unit Tests**:
```swift
class BitchatFilePacketTests: XCTestCase {
    func testTLVEncodeDecode() // Test exact Android compatibility
    func testSizeLimits() // Test 5MB enforcement
    func testMalformedPackets() // Test error handling
}

class VoiceRecorderTests: XCTestCase {
    func testRecordingLimits() // Test 5MB size cutoff
    func testAudioFormat() // Verify M4A output
    func testBackgroundRecording() // Test app backgrounding
}
```

**Integration Tests**:
```swift
class FileTransferIntegrationTests: XCTestCase {
    func testBLELoopback() // Local BLE transfer test
    func testNostrRelay() // Test with live Nostr relay
    func testMeshToNostrFallback() // Test automatic fallback
}
```

**UI Tests**:
```swift
class FileTransferUITests: XCTestCase {
    func testFilePicker() // Test all picker variants
    func testVoiceRecording() // Test recording workflow
    func testTransferProgress() // Test progress UI updates
    func testErrorHandling() // Test error message display
}
```

**Cross-Platform Tests**:
- **Android interop**: Send/receive files between iOS and Android (PR #440)
- **Protocol compliance**: Verify TLV format matches exactly
- **Size limit consistency**: Ensure both platforms enforce 5MB identically
- **Error handling parity**: Test error scenarios on both platforms

### 11. Documentation & Developer Guide

**Documentation Updates**:

1. **README.md** - Add "File Transfer" section:
   - Architecture overview (mesh vs off-mesh)
   - Supported file types and size limits
   - Cross-platform compatibility notes

2. **Technical Documentation**:
   - TLV packet format specification
   - BitchatFilePacket API reference
   - Transfer progress monitoring guide
   - Error handling best practices

3. **Developer Guide**:
   - Adding new MIME type support
   - Customizing file size limits
   - Implementing custom transfer protocols
   - Debugging transfer issues

## File Size Limits & Compatibility

### Size Constraints
- **Maximum file size**: 5MB (5 * 1024 * 1024 bytes)
- **Enforcement points**: 
  - File picker (pre-selection validation)
  - Voice recorder (real-time monitoring)
  - BitchatFilePacket encoding (validation)
  - BLE/Nostr transport layers (final check)

### Cross-Platform Consistency
Both iOS and Android will:
- Use identical TLV format for BitchatFilePacket
- Enforce the same 5MB size limit
- Support the same MIME types
- Use compatible voice recording formats (M4A)
- Provide consistent error messages

## Implementation Timeline

### Phase 1 (Week 1-2): Core Infrastructure
- [ ] BitchatFilePacket TLV format
- [ ] FileUtils MIME/storage helpers
- [ ] Basic transfer progress tracking

### Phase 2 (Week 3-4): Transfer Mechanisms  
- [ ] VoiceRecorder implementation
- [ ] Enhanced FileTransferService (BLE)
- [ ] Nostr relay fallback support

### Phase 3 (Week 5-6): User Interface
- [ ] File picker components
- [ ] Voice recorder UI with waveforms
- [ ] Media preview and progress indicators

### Phase 4 (Week 7-8): Testing & Polish
- [ ] Comprehensive test suite
- [ ] Android interoperability testing
- [ ] Error handling and edge cases
- [ ] Performance optimization

### Phase 5 (Week 9): Documentation & Release
- [ ] Documentation updates
- [ ] API reference generation
- [ ] Release preparation

## Success Criteria

### Technical Requirements ✅
- [ ] 100% TLV format compatibility with Android PR #440
- [ ] 5MB file size limit enforced consistently
- [ ] Voice recording in M4A format < 5MB
- [ ] Real-time transfer progress with cancellation
- [ ] Graceful mesh-to-Nostr fallback
- [ ] Comprehensive error handling

### User Experience Goals ✅
- [ ] Intuitive file picker interface
- [ ] Clear transfer progress indicators
- [ ] Responsive voice recording with visual feedback
- [ ] Seamless media preview and playback
- [ ] Helpful error messages and recovery options

### Cross-Platform Validation ✅
- [ ] Send files from iOS → Android (PR #440)
- [ ] Receive files from Android → iOS 
- [ ] Voice notes compatible both directions
- [ ] Progress tracking works identically
- [ ] Error scenarios handled consistently

## Risk Mitigation

### Technical Risks
- **TLV format mismatch**: Implement comprehensive test suite with Android-generated packets
- **BLE reliability**: Add robust error recovery and retry mechanisms  
- **Memory usage**: Stream large files instead of loading entirely into memory
- **Background limits**: Test voice recording during app backgrounding scenarios

### User Experience Risks
- **Transfer failures**: Provide clear error messages and retry options
- **Performance impact**: Optimize for battery usage during long transfers
- **Storage limits**: Check available space before transfers
- **Network reliability**: Implement graceful degradation between mesh/Nostr

## Conclusion

This implementation plan provides a comprehensive roadmap for adding robust file transfer capabilities to the iOS BitChat app, ensuring full compatibility with the Android implementation in PR #440. The focus on cross-platform consistency, comprehensive testing, and user experience will result in a seamless file sharing experience across both platforms while maintaining the decentralized, privacy-focused principles of BitChat.

The staged approach allows for iterative development and testing, ensuring each component works correctly before building upon it. The emphasis on automated testing and cross-platform validation will help catch compatibility issues early in the development process.