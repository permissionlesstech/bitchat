import SwiftUI

struct VoiceMessageView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var audioService = AudioService.shared
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showingRecordingSheet = false
    @State private var recordedAudioData: Data?
    @State private var recordedDuration: TimeInterval = 0
    
    private var backgroundColor: Color {
            ThemeManager.backgroundColor(for: colorScheme)
        }
        
        private var textColor: Color {
            ThemeManager.textColor(for: colorScheme)
        }
        
        private var secondaryTextColor: Color {
            ThemeManager.secondaryTextColor(for: colorScheme)
        }
    
    var body: some View {
        HStack {
            // Voice message recording button
            Button(action: {
                showingRecordingSheet = true
            }) {
                Image(systemName: "mic.fill")
                    .foregroundColor(textColor)
                    .font(.system(size: 20))
                    .padding(8)
                    .background(Circle().fill(textColor.opacity(0.1)))
            }
            .sheet(isPresented: $showingRecordingSheet) {
                VoiceRecordingSheet(
                    audioService: audioService,
                    onRecordingComplete: { audioData, duration in
                        recordedAudioData = audioData
                        recordedDuration = duration
                        sendVoiceMessage(audioData, duration: duration)
                    }
                )
                .presentationDetents([.fraction(0.7)])
            }
        }
    }
    
    private func sendVoiceMessage(_ audioData: Data, duration: TimeInterval) {
        if let selectedPeer = viewModel.selectedPrivateChatPeer {
            // Send as private voice message
            viewModel.sendVoiceMessage(audioData, duration: duration, to: selectedPeer)
        } else {
            // Send as broadcast voice message
            viewModel.sendVoiceMessage(audioData, duration: duration)
        }
    }
}

enum RecordingState {
    case ready
    case recording
    case preview
}

struct VoiceRecordingSheet: View {
    @ObservedObject var audioService: AudioService
    @State private var recordingStartTime: Date?
    @State private var recordingState: RecordingState = .ready
    @State private var recordedAudioData: Data?
    @State private var recordedDuration: TimeInterval = 0
    @State private var isPlayingPreview = false
    @State private var showingErrorAlert = false
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    let onRecordingComplete: (Data, TimeInterval) -> Void
    
    // Theme colors using centralized ThemeManager
    private var backgroundColor: Color {
        ThemeManager.backgroundColor(for: colorScheme)
    }
    
    private var textColor: Color {
        ThemeManager.textColor(for: colorScheme)
    }
    
    private var secondaryTextColor: Color {
        ThemeManager.secondaryTextColor(for: colorScheme)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Handle bar for sheet
            RoundedRectangle(cornerRadius: 2)
                .fill(secondaryTextColor.opacity(0.3))
                .frame(width: 40, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 12)
            
            VStack(spacing: 20) {
                Text(recordingState == .preview ? "voice_preview*" : "voice_message*")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                
                // Error display
                if let error = audioService.recordingError {
                    Text(error)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                )
                        )
                }
                
                // Recording/Preview status
                VStack(spacing: 12) {
                    switch recordingState {
                    case .ready:
                        Text("ready_to_record")
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        
                        Text("00:00")
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(secondaryTextColor)
                        
                        // Show size estimation during long recordings
                        if audioService.recordingDuration > 30 {
                            let estimatedSize = audioService.getEstimatedSize()
                            let maxSize = 60000 // Same limit as in AudioService
                            let percentage = Double(estimatedSize) / Double(maxSize) * 100
                            
                            Text("~\(estimatedSize/1024)KB (\(String(format: "%.0f", percentage))% of limit)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(percentage > 80 ? .red : secondaryTextColor)
                        }
                        
                        // Show remaining time warning
                        let remainingTime = 120 - audioService.recordingDuration
                        if remainingTime < 30 {
                            Text("~\(Int(remainingTime))s remaining")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                        
                    case .recording:
                        HStack(spacing: 8) {
                            // Blinking recording indicator
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .scaleEffect(audioService.isRecording ? 1.3 : 1.0)
                                .animation(.easeInOut(duration: 0.8).repeatForever(), value: audioService.isRecording)
                            
                            Text("recording...")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.red)
                        }
                        
                        Text(audioService.formatDuration(audioService.recordingDuration))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        // Show size estimation during long recordings
                        if audioService.recordingDuration > 30 {
                            let estimatedSize = audioService.getEstimatedSize()
                            let maxSize = 60000 // Same limit as in AudioService
                            let percentage = Double(estimatedSize) / Double(maxSize) * 100
                            
                            Text("~\(estimatedSize/1024)KB (\(String(format: "%.0f", percentage))% of limit)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(percentage > 80 ? .red : secondaryTextColor)
                        }
                        
                        // Show remaining time warning
                        let remainingTime = 120 - audioService.recordingDuration
                        if remainingTime < 30 {
                            Text("~\(Int(remainingTime))s remaining")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                        
                    case .preview:
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundColor(.green)
                            
                            Text("preview_ready")
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(.green)
                        }
                        
                        Text(audioService.formatDuration(recordedDuration))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)
                        
                        // Preview playback progress
                        VStack(spacing: 8) {
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(secondaryTextColor.opacity(0.3))
                                    .frame(height: 4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.green)
                                            .frame(width: max(0, geometry.size.width * (audioService.playbackProgress / recordedDuration)))
                                            .animation(.linear(duration: 0.1), value: audioService.playbackProgress),
                                        alignment: .leading
                                    )
                            }
                            .frame(height: 4)
                            
                            Text("\(audioService.formatDuration(audioService.playbackProgress)) / \(audioService.formatDuration(recordedDuration))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
                        )
                )
                
                // Controls based on state
                switch recordingState {
                case .ready:
                    readyControls
                case .recording:
                    recordingControls
                case .preview:
                    previewControls
                }
                
                // Instructions
                Text(getInstructionText())
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .padding(.bottom)
                
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(secondaryTextColor.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.top, 5)
        .background(backgroundColor)
        .preferredColorScheme(colorScheme)
        .onReceive(audioService.$isPlaying) { playing in
            if !playing && isPlayingPreview {
                // Playback finished, reset to beginning
                isPlayingPreview = false
            }
        }
        .onReceive(audioService.$recordingError) { error in
            if error != nil {
                showingErrorAlert = true
            }
        }
        .alert("Recording Error", isPresented: $showingErrorAlert) {
            Button("OK") {
                audioService.recordingError = nil
                if recordingState == .recording {
                    recordingState = .ready
                }
            }
        } message: {
            Text(audioService.recordingError ?? "Unknown error")
        }
    }
    
    private var readyControls: some View {
        HStack(spacing: 50) {
            // Cancel button
            Button(action: {
                dismiss()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 50, weight: .light))
                        .foregroundColor(Color.red)
                    
                    Text("cancel")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Record button
            Button(action: {
                _ = audioService.startRecording()
                recordingStartTime = Date()
                recordingState = .recording
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 70, weight: .light))
                        .foregroundColor(textColor)
                    
                    Text("record")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Spacer to maintain layout
            Color.clear
                .frame(width: 50, height: 66)
        }
        .padding(.horizontal)
    }
    
    private var recordingControls: some View {
        HStack(spacing: 50) {
            // Cancel button
            Button(action: {
                audioService.cancelRecording()
                recordingState = .ready
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 50, weight: .light))
                        .foregroundColor(Color.red)
                    
                    Text("cancel")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Stop button
            Button(action: {
                if let audioData = audioService.stopRecording() {
                    recordedAudioData = audioData
                    recordedDuration = audioService.recordingDuration
                    recordingState = .preview
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 70, weight: .light))
                        .foregroundColor(Color.red)
                    
                    Text("stop")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Spacer to maintain layout
            Color.clear
                .frame(width: 50, height: 66)
        }
        .padding(.horizontal)
    }
    
    private var previewControls: some View {
        HStack(alignment: .top, spacing: 30) {
            // Record again button
            Button(action: {
                audioService.stopPlayback()
                recordedAudioData = nil
                recordedDuration = 0
                isPlayingPreview = false
                recordingState = .ready
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Color.orange)
                    
                    Text("again")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Play/Pause button
            Button(action: {
                if isPlayingPreview {
                    audioService.stopPlayback()
                    isPlayingPreview = false
                } else {
                    if let audioData = recordedAudioData {
                        let decompressedData = AudioService.shared.decompressAudioData(audioData) ?? audioData
                        audioService.playAudio(decompressedData, duration: recordedDuration)
                        isPlayingPreview = true
                    }
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: isPlayingPreview ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.green)
                    
                    Text(isPlayingPreview ? "pause" : "play")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Cancel button
            Button(action: {
                audioService.stopPlayback()
                dismiss()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(Color.red)
                    
                    Text("cancel")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .buttonStyle(.plain)
            
            // Send button
            Button(action: {
                if let audioData = recordedAudioData {
                    audioService.stopPlayback()
                    onRecordingComplete(audioData, recordedDuration)
                    dismiss()
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.green)
                    
                    Text("send")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(textColor)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }
    
    private func getInstructionText() -> String {
        switch recordingState {
        case .ready:
            return "> tap_record_to_start"
        case .recording:
            return "> tap_stop_to_finish"
        case .preview:
            return "> play_to_listen_send_to_confirm"
        }
    }
}

struct VoiceMessageBubble: View {
    let message: BitchatMessage
    @StateObject private var audioService = AudioService.shared
    @State private var isPlaying = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Play/Pause button
            Button(action: {
                togglePlayback()
            }) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                // Simple progress bar
                if let duration = message.audioDuration {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.green)
                                    .frame(width: max(0, geometry.size.width * (audioService.playbackProgress / duration)))
                                    .animation(.linear(duration: 0.1), value: audioService.playbackProgress),
                                alignment: .leading
                            )
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(12)
        .padding(.bottom)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.green.opacity(0.1)))
        .onAppear {
            // Update playing state based on audio service
            isPlaying = audioService.isPlaying
        }
        .onReceive(audioService.$isPlaying) { playing in
            isPlaying = playing
        }
        .overlay(
            // Duration
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    
                    if let duration = message.audioDuration {
                        Text(audioService.formatDuration(duration))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }.padding(),
            alignment: .bottomTrailing
        )
    }
    
    private func togglePlayback() {
        if isPlaying {
            audioService.stopPlayback()
        } else {
            if let audioData = message.audioData,
               let duration = message.audioDuration {
                // Decompress audio data if needed
                let decompressedData = AudioService.shared.decompressAudioData(audioData) ?? audioData
                audioService.playAudio(decompressedData, duration: duration)
            }
        }
    }
}
