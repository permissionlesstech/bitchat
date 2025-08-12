//
// VoiceRecordingView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI
import AVFoundation

/// Voice recording interface integrated with BitChat's design system
/// Provides hold-to-record functionality with visual feedback and cancel gestures
struct VoiceRecordingView: View {
    // MARK: - Properties
    
    @Environment(\.colorScheme) var colorScheme
    @Binding var isRecording: Bool
    @Binding var recordingDuration: TimeInterval
    @Binding var currentAmplitude: Float
    
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onCancelRecording: () -> Void
    
    // Haptic feedback manager - using direct singleton access
    // private lazy var hapticManager = HapticFeedbackManager.shared
    
    @State private var dragOffset: CGFloat = 0
    @State private var showCancelHint = false
    @State private var pulseAnimation = false
    
    // MARK: - Computed Properties
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var recordingButtonColor: Color {
        isRecording ? Color.red : textColor
    }
    
    // MARK: - Body
    
    var body: some View {
        HStack(spacing: 12) {
            if isRecording {
                recordingInterface
            } else {
                recordButton
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isRecording)
    }
    
    // MARK: - Recording Interface
    
    private var recordingInterface: some View {
        HStack(spacing: 12) {
            // Cancel hint (appears when dragging left)
            if showCancelHint {
                Text("< Cancel")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.red)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            
            Spacer()
            
            // Recording duration and waveform
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    // Recording indicator
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), 
                                  value: pulseAnimation)
                    
                    // Duration
                    Text(formattedDuration)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                        .accessibilityLabel("Recording duration: \(formattedDuration)")
                }
                
                // Optimized waveform visualization
                // OptimizedWaveformView(
                //     samples: generateWaveformSamples(amplitude: currentAmplitude),
                //     color: textColor
                // )
                // .frame(height: 20)
                // .performanceOptimized()
                // .accessibilityLabel("Voice level waveform")
                // .accessibilityValue("Current level: \(Int(currentAmplitude * 100))%")
                
                // Simple waveform replacement
                Rectangle()
                    .fill(textColor.opacity(0.3))
                    .frame(height: 20)
            }
            
            Spacer()
            
            // Send/Stop button
            Button(action: {
                print("🔵 DEBUG: VoiceRecordingView Button onStopRecording() called")
                let debugMsg = "🔵 DEBUG: VoiceRecordingView Button onStopRecording() called"
                try? debugMsg.write(to: URL(fileURLWithPath: "/tmp/bitchat_debug.log"), atomically: false, encoding: .utf8)
                onStopRecording()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(recordingButtonColor)
            }
            .buttonStyle(.plain)
            .offset(x: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let translation = value.translation.width
                        dragOffset = min(0, translation) // Only allow left drag
                        
                        // Show cancel hint when dragged significantly left
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showCancelHint = translation < -50
                        }
                    }
                    .onEnded { value in
                        let translation = value.translation.width
                        let velocity = value.velocity.width
                        
                        withAnimation(.easeOut(duration: 0.2)) {
                            if translation < -80 || (translation < -40 && velocity < -300) {
                                // Cancel recording
                                // Haptic feedback for recording cancellation
                                HapticFeedbackManager.shared.triggerHaptic(for: .recordingCancelled)
                                onCancelRecording()
                                showCancelHint = false
                                dragOffset = 0
                            } else if abs(translation) < 20 && abs(velocity) < 100 {
                                // Tap to send
                                print("🟡 DEBUG: VoiceRecordingView Gesture onStopRecording() called")
                                let debugMsg = "🟡 DEBUG: VoiceRecordingView Gesture onStopRecording() called"
                                try? debugMsg.write(to: URL(fileURLWithPath: "/tmp/bitchat_debug.log"), atomically: false, encoding: .utf8)
                                // hapticManager.triggerHaptic(for: .recordingStopped)
                                onStopRecording()
                                showCancelHint = false
                                dragOffset = 0
                            } else {
                                // Return to original position
                                showCancelHint = false
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityLabel("Stop recording and send voice message")
            .accessibilityHint("Drag left to cancel, tap to send")
            .accessibilityActions {
                Button("Send voice message") {
                    print("🟢 DEBUG: VoiceRecordingView Accessibility onStopRecording() called")
                    let debugMsg = "🟢 DEBUG: VoiceRecordingView Accessibility onStopRecording() called"
                    try? debugMsg.write(to: URL(fileURLWithPath: "/tmp/bitchat_debug.log"), atomically: false, encoding: .utf8)
                    onStopRecording()
                }
                Button("Cancel recording") {
                    onCancelRecording()
                }
            }
        }
        .onAppear {
            pulseAnimation = true
            // hapticManager.prepareForVoiceInteraction()
        }
        .onDisappear {
            pulseAnimation = false
        }
    }
    
    // MARK: - Record Button
    
    private var recordButton: some View {
        Button(action: {
            print("🎤 DEBUG: Record button tapped!")
            let tapMsg = "🎤 DEBUG: VoiceRecordingView Button action (tap) triggered"
            try? tapMsg.write(to: URL(fileURLWithPath: "/tmp/bitchat_debug.log"), atomically: false, encoding: .utf8)
            // Allow tap to start recording as well as long press
            // hapticManager.triggerHaptic(for: .recordingStarted)
            onStartRecording()
        }) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(Color.green)
        }
        .buttonStyle(.plain)
        .scaleEffect(1.0)
        .onLongPressGesture(
            minimumDuration: 0.1,
            maximumDistance: 50
        ) {
            print("🎤 DEBUG: Record button long pressed!")
            let gestureMsg = "🎤 DEBUG: VoiceRecordingView onLongPressGesture triggered"
            try? gestureMsg.write(to: URL(fileURLWithPath: "/tmp/bitchat_debug.log"), atomically: false, encoding: .utf8)
            // Start recording on long press
            // hapticManager.triggerHaptic(for: .recordingStarted)
            onStartRecording()
        }
        .accessibilityLabel("Record voice message")
        .accessibilityHint("Tap or press and hold to start recording")
        .accessibilityActions {
            Button("Start recording") {
                print("🎤 DEBUG: Accessibility Start recording button pressed!")
                let accessibilityMsg = "🎤 DEBUG: VoiceRecordingView accessibility Start recording triggered"
                try? accessibilityMsg.write(to: URL(fileURLWithPath: "/tmp/bitchat_debug.log"), atomically: false, encoding: .utf8)
                onStartRecording()
            }
        }
    }
    
    // MARK: - Helpers
    
    private var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Generates optimized waveform samples for real-time visualization
    private func generateWaveformSamples(amplitude: Float) -> [Float] {
        // Generate optimized sample data based on current amplitude
        let sampleCount = 20 // Reduced for performance
        var samples: [Float] = []
        
        for i in 0..<sampleCount {
            let normalizedPos = Float(i) / Float(sampleCount - 1)
            let waveValue = amplitude * sin(normalizedPos * .pi * 4) * (1.0 - normalizedPos * 0.3)
            samples.append(abs(waveValue))
        }
        
        return samples
    }
}

// MARK: - Waveform Visualization

/// Simple waveform visualization for voice recording
/// Optimized for real-time performance with reduced animation overhead
struct WaveformView: View {
    let amplitude: Float
    let color: Color
    
    @State private var waveformData: [Float] = Array(repeating: 0.0, count: 20)
    @State private var lastUpdateTime: Date = Date()
    
    // Performance optimization: limit update frequency
    private let updateThreshold: TimeInterval = 0.05 // 20 FPS max
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<waveformData.count, id: \.self) { index in
                Rectangle()
                    .fill(color)
                    .frame(width: 3, height: max(2, CGFloat(waveformData[index]) * 20))
                    // Reduce animation complexity for performance
                    .animation(.linear(duration: 0.1), value: waveformData[index])
            }
        }
        .onChange(of: amplitude) { newAmplitude in
            // Throttle updates for performance
            throttledUpdateWaveform(amplitude: newAmplitude)
        }
    }
    
    private func throttledUpdateWaveform(amplitude: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= updateThreshold else { return }
        
        lastUpdateTime = now
        updateWaveform(amplitude: amplitude)
    }
    
    private func updateWaveform(amplitude: Float) {
        // Optimized array manipulation
        if waveformData.count >= 20 {
            waveformData.removeFirst()
        }
        waveformData.append(amplitude)
    }
}

// MARK: - Preview

struct VoiceRecordingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Recording state
            VoiceRecordingView(
                isRecording: .constant(true),
                recordingDuration: .constant(15.5),
                currentAmplitude: .constant(0.7),
                onStartRecording: {},
                onStopRecording: {},
                onCancelRecording: {}
            )
            .padding()
            .previewDisplayName("Recording")
            
            // Idle state
            VoiceRecordingView(
                isRecording: .constant(false),
                recordingDuration: .constant(0),
                currentAmplitude: .constant(0),
                onStartRecording: {},
                onStopRecording: {},
                onCancelRecording: {}
            )
            .padding()
            .previewDisplayName("Idle")
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
    }
}