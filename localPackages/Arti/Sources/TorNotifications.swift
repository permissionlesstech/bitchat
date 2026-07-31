import Foundation

public extension Notification.Name {
    static let TorDidBecomeReady = Notification.Name("TorDidBecomeReady")
    static let TorWillRestart = Notification.Name("TorWillRestart")
    static let TorWillStart = Notification.Name("TorWillStart")
    static let TorUserPreferenceChanged = Notification.Name("TorUserPreferenceChanged")
}
