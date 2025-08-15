//
// VoiceMessageView.swift  
// bitchat
//
// Voice message display with waveform and playback controls
//

import SwiftUI
import AVFoundation

struct VoiceMessageView: View {
    let message: BitchatMessage  // Use full message instead of just voiceData
    let isFromCurrentUser: Bool
    
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var chatViewModel: ChatViewModel  // Use ChatViewModel for playback
    
    // Computed properties from message
    private var voiceData: VoiceMessageData? {
        message.voiceMessageData
    }
    
    private var isPlaying: Bool {
        if case .playing(let messageID) = chatViewModel.voicePlaybackState,
           messageID == message.id {
            return true
        }
        return false
    }
    
    private var currentProgress: Double {
        if case .playing(let messageID) = chatViewModel.voicePlaybackState,
           messageID == message.id {
            return chatViewModel.voicePlaybackProgress
        }
        return 0.0
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.3) : Color.gray.opacity(0.1)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause button - Uses ChatViewModel architecture
            Button(action: {
                print("🎵 VoiceMessageView: Play button tapped for message: \(message.id)")
                chatViewModel.playPauseVoiceMessage(message)
            }) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(textColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause voice message" : "Play voice message")
            
            VStack(alignment: .leading, spacing: 4) {
                // Waveform visualization
                if let voiceData = voiceData {
                    WaveformViewForVoiceMessage(
                        waveformData: voiceData.waveformData,
                        progress: voiceData.duration > 0 ? currentProgress : 0,
                        color: textColor
                    )
                    .frame(height: 40)
                    
                    HStack {
                        Text(formatTime(currentProgress * voiceData.duration))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                        
                        Spacer()
                        
                        Text(voiceData.formattedDuration)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                    }
                } else {
                    // Fallback if no voice data
                    Text("Voice message")
                        .font(.caption)
                        .foregroundColor(textColor.opacity(0.7))
                }
            }
        }
        .padding(12)
        .background(backgroundColor)
        .cornerRadius(12)
    }
    
    // MARK: - Helper Methods
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// Simple waveform visualization for voice messages
struct WaveformViewForVoiceMessage: View {
    let waveformData: [Float]
    let progress: Double
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<min(waveformData.count, Int(geometry.size.width / 3)), id: \.self) { index in
                    let amplitude = waveformData.indices.contains(index) ? waveformData[index] : 0.5
                    let height = max(4, CGFloat(amplitude) * geometry.size.height)
                    let isPlayed = Double(index) / Double(waveformData.count) < progress
                    
                    Rectangle()
                        .fill(isPlayed ? color : color.opacity(0.3))
                        .frame(width: 2, height: height)
                        .cornerRadius(1)
                }
                
                // If we have fewer data points than available width, fill with default bars
                let dataCount = min(waveformData.count, Int(geometry.size.width / 3))
                let remainingBars = Int(geometry.size.width / 3) - dataCount
                
                ForEach(0..<remainingBars, id: \.self) { _ in
                    Rectangle()
                        .fill(color.opacity(0.2))
                        .frame(width: 2, height: 8)
                        .cornerRadius(1)
                }
            }
        }
    }
}

// Preview
struct VoiceMessageView_Previews: PreviewProvider {
    static var previews: some View {
        let mockVoiceData = VoiceMessageData(
            duration: 15.3,
            waveformData: (0..<50).map { _ in Float.random(in: 0.2...1.0) },
            filePath: nil,
            audioData: Data(),
            format: .opus
        )
        
        let mockMessage = BitchatMessage(
            id: "mock-voice-message",
            sender: "TestUser",
            content: "🎤 Voice message",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: "test-peer",
            mentions: nil,
            deliveryStatus: .sent,
            voiceMessageData: mockVoiceData
        )
        
        VStack(spacing: 20) {
            VoiceMessageView(message: mockMessage, isFromCurrentUser: true)
                .environmentObject(ChatViewModel())
            VoiceMessageView(message: mockMessage, isFromCurrentUser: false)
                .environmentObject(ChatViewModel())
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}