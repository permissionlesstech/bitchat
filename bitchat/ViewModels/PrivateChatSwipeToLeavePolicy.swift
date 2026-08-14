import CoreGraphics

/// Decides whether a drag on the private-chat message list should end the
/// conversation.
///
/// The swipe-right-to-leave gesture is attached to the message list with
/// `highPriorityGesture`, which starves gestures on descendant views. A playing
/// voice note overlays its waveform with a seek `DragGesture(minimumDistance: 0)`,
/// so a drag meant to scrub playback never reaches the waveform, and one that
/// happens to travel far enough to the right leaves the conversation instead.
///
/// While audio is playing the seek is the intent the reader is far more likely
/// to have, so the leave gesture stands down for the duration of playback.
/// Leaving remains available through the sidebar.
enum PrivateChatSwipeToLeavePolicy {
    /// Rightward travel a drag must exceed before it counts as a leave.
    static let minimumHorizontalTranslation: CGFloat = 80

    /// Vertical travel above which a drag reads as a scroll, not a leave.
    static let maximumVerticalTranslation: CGFloat = 60

    static func shouldLeave(translation: CGSize, isVoiceNotePlaying: Bool) -> Bool {
        guard !isVoiceNotePlaying else { return false }
        return translation.width > minimumHorizontalTranslation
            && abs(translation.height) < maximumVerticalTranslation
    }
}
