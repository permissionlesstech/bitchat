import Testing
@testable import bitchat

struct BLEPeerListRefreshThrottleTests {
    @Test
    func firstRequestRefreshesImmediately() {
        var throttle = BLEPeerListRefreshThrottle()
        let refresh = throttle.requestRefresh()

        #expect(refresh)
    }

    @Test
    func requestsDuringWindowCollapseIntoOneTrailingRefresh() {
        var throttle = BLEPeerListRefreshThrottle()
        let leading = throttle.requestRefresh()
        var refreshesInWindow = 0
        for _ in 0..<50 where throttle.requestRefresh() {
            refreshesInWindow += 1
        }
        let trailing = throttle.windowEnded()
        let afterTrailing = throttle.windowEnded()

        #expect(leading)
        #expect(refreshesInWindow == 0)
        #expect(trailing)
        #expect(!afterTrailing)
    }

    @Test
    func windowWithoutRequestsCloses() {
        var throttle = BLEPeerListRefreshThrottle()
        _ = throttle.requestRefresh()
        let trailing = throttle.windowEnded()
        let next = throttle.requestRefresh()

        #expect(!trailing)
        #expect(next)
    }

    @Test
    func requestAfterCloseRefreshesImmediately() {
        var throttle = BLEPeerListRefreshThrottle()
        _ = throttle.requestRefresh()
        _ = throttle.requestRefresh()
        _ = throttle.windowEnded()  // trailing refresh, window stays open
        _ = throttle.windowEnded()  // quiet window closes
        let next = throttle.requestRefresh()

        #expect(next)
    }

    @Test
    func staleWindowEndWhileClosedIsIgnored() {
        var throttle = BLEPeerListRefreshThrottle()
        let stale = throttle.windowEnded()
        let first = throttle.requestRefresh()

        #expect(!stale)
        #expect(first)
    }

    /// A busy mesh never goes quiet: changes keep arriving, and the list is
    /// refreshed once per window — the leading refresh plus one trailing
    /// refresh per window, however many changes each window saw.
    @Test
    func sustainedRequestsRefreshOncePerWindow() {
        var throttle = BLEPeerListRefreshThrottle()
        var refreshes = throttle.requestRefresh() ? 1 : 0
        for _ in 0..<3 {
            for _ in 0..<20 where throttle.requestRefresh() {
                refreshes += 1
            }
            if throttle.windowEnded() {
                refreshes += 1
            }
        }

        let quietWindowRefreshes = throttle.windowEnded()
        let next = throttle.requestRefresh()

        #expect(refreshes == 4)
        #expect(!quietWindowRefreshes)
        #expect(next)
    }
}
