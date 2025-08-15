//
// HapticFeedbackManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// Manages haptic feedback for voice messaging interactions
/// Provides contextual haptic feedback to enhance user experience (iOS only)
public final class HapticFeedbackManager {
    
    // MARK: - Singleton
    
    public static let shared = HapticFeedbackManager()
    
    // MARK: - Haptic Feedback Types
    
    public enum VoiceHapticEvent {
        case recordingStarted
        case recordingStopped
        case recordingCancelled
        case voiceMessageSent
        case voiceMessageReceived
        case playbackStarted
        case playbackPaused
        case playbackCompleted
        case seekingStarted
        case seekingCompleted
        case errorOccurred
        case permissionDenied
    }
    
    // MARK: - Properties
    
    #if os(iOS)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()
    #endif
    
    private var isHapticEnabled: Bool = true
    
    // MARK: - Initialization
    
    private init() {
        setupHapticGenerators()
    }
    
    // MARK: - Public API
    
    /// Enable or disable haptic feedback
    public func setHapticEnabled(_ enabled: Bool) {
        isHapticEnabled = enabled
    }
    
    /// Trigger haptic feedback for voice events
    public func triggerHaptic(for event: VoiceHapticEvent) {
        guard isHapticEnabled else { return }
        
        #if os(iOS)
        switch event {
        case .recordingStarted:
            impactMedium.impactOccurred()
            
        case .recordingStopped:
            impactLight.impactOccurred()
            
        case .recordingCancelled:
            notificationGenerator.notificationOccurred(.warning)
            
        case .voiceMessageSent:
            notificationGenerator.notificationOccurred(.success)
            
        case .voiceMessageReceived:
            impactLight.impactOccurred()
            
        case .playbackStarted:
            selectionGenerator.selectionChanged()
            
        case .playbackPaused:
            selectionGenerator.selectionChanged()
            
        case .playbackCompleted:
            impactLight.impactOccurred()
            
        case .seekingStarted:
            selectionGenerator.selectionChanged()
            
        case .seekingCompleted:
            selectionGenerator.selectionChanged()
            
        case .errorOccurred:
            notificationGenerator.notificationOccurred(.error)
            
        case .permissionDenied:
            notificationGenerator.notificationOccurred(.error)
        }
        #endif
    }
    
    /// Trigger continuous haptic feedback during recording (amplitude-based)
    public func triggerRecordingFeedback(amplitude: Float) {
        guard isHapticEnabled else { return }
        
        #if os(iOS)
        // Provide subtle feedback based on voice amplitude
        if amplitude > 0.7 {
            impactLight.impactOccurred(intensity: 0.5)
        } else if amplitude > 0.4 {
            impactLight.impactOccurred(intensity: 0.3)
        }
        #endif
    }
    
    /// Prepare haptic generators for upcoming use
    public func prepareForVoiceInteraction() {
        #if os(iOS)
        impactLight.prepare()
        impactMedium.prepare()
        selectionGenerator.prepare()
        #endif
    }
    
    // MARK: - Private Methods
    
    private func setupHapticGenerators() {
        #if os(iOS)
        // Prepare generators for immediate use
        impactLight.prepare()
        impactMedium.prepare()
        impactHeavy.prepare()
        notificationGenerator.prepare()
        selectionGenerator.prepare()
        #endif
    }
}

// MARK: - SwiftUI Integration

#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI view modifier for adding haptic feedback to voice interactions
public struct VoiceHapticModifier: ViewModifier {
    let event: HapticFeedbackManager.VoiceHapticEvent
    
    public func body(content: Content) -> some View {
        content
            .onTapGesture {
                HapticFeedbackManager.shared.triggerHaptic(for: event)
            }
    }
}

extension View {
    /// Add haptic feedback for voice interactions
    public func voiceHapticFeedback(_ event: HapticFeedbackManager.VoiceHapticEvent) -> some View {
        self.modifier(VoiceHapticModifier(event: event))
    }
}
#endif