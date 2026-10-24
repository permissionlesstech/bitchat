import Foundation

/// Throttles the peer-list refresh (snapshot publish plus `.peerListUpdated`)
/// that verified announces request.
///
/// A crowd re-announces every ~10 s, so a node hears about N/10 announces a
/// second, and each used to deliver its own refresh: O(N) main-actor work
/// per announce, O(N^2) per second. The first change after a quiet window
/// refreshes immediately; every further change inside the window collapses
/// into one trailing refresh, which reads the registry when it runs.
///
/// Clock-free on purpose: the caller schedules `windowEnded()` one interval
/// after each refresh it is told to deliver, on the engine scheduler, so
/// tests drive windows with the manual clock. (`BLEPeerPublishCoalescer`
/// reads `Date()` instead, which a manually clocked mesh can't advance.)
/// Engine-confined.
struct BLEPeerListRefreshThrottle {
    private var windowOpen = false
    private var refreshPending = false

    /// Records a peer-list change. Returns `true` when the caller should
    /// refresh now and call `windowEnded()` one interval later; `false`
    /// when a window is open and the change rides its trailing refresh.
    mutating func requestRefresh() -> Bool {
        guard !windowOpen else {
            refreshPending = true
            return false
        }
        windowOpen = true
        return true
    }

    /// The window opened by the last refresh elapsed. Returns `true` when a
    /// change arrived during it: refresh now and call `windowEnded()` again
    /// one interval later. Otherwise the window closes, so the next change
    /// refreshes immediately.
    mutating func windowEnded() -> Bool {
        guard windowOpen, refreshPending else {
            windowOpen = false
            return false
        }
        refreshPending = false
        return true
    }
}
