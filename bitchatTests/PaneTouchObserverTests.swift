#if os(iOS)
import Testing
import UIKit
@testable import bitchat

/// The split layout watches touches from the window (spec 2.6). It must never
/// take part in gesture handling: whatever the person touches keeps working
/// exactly as it would without the observer. UIKit only runs a recognizer's
/// state machine while it delivers real touches, so the failure at
/// touch-down is left to the device pass; its configuration and its place
/// on the window are pinned here.
@MainActor
struct PaneTouchObserverTests {
    @Test
    func recognizerNeverHoldsUpOtherGestures() throws {
        let recognizer = PassiveTouchDownRecognizer()
        let other = UIPanGestureRecognizer()

        #expect(!recognizer.cancelsTouchesInView)
        #expect(!recognizer.delaysTouchesBegan)
        #expect(!recognizer.delaysTouchesEnded)
        #expect(!recognizer.canPrevent(other))
        #expect(!recognizer.canBePrevented(by: other))

        let delegate = try #require(recognizer.delegate)
        #expect(delegate.gestureRecognizer?(recognizer, shouldRecognizeSimultaneouslyWith: other) == true)
        #expect(delegate.gestureRecognizer?(recognizer, shouldRequireFailureOf: other) == false)
        #expect(delegate.gestureRecognizer?(recognizer, shouldBeRequiredToFailBy: other) == false)
    }

    @Test
    func observerWatchesTheWindowItIsIn() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let otherWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let observer = PaneTouchObserverView()

        // It takes no touches of its own.
        #expect(!observer.isUserInteractionEnabled)
        #expect(observer.recognizer.view == nil)

        window.addSubview(observer)
        #expect(observer.recognizer.view === window)
        #expect(window.gestureRecognizers?.contains(observer.recognizer) == true)

        otherWindow.addSubview(observer)
        #expect(observer.recognizer.view === otherWindow)
        #expect(window.gestureRecognizers?.contains(observer.recognizer) != true)

        observer.removeFromSuperview()
        #expect(observer.recognizer.view == nil)
        #expect(otherWindow.gestureRecognizers?.contains(observer.recognizer) != true)
    }

    @Test
    func dismantlingLeavesTheWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let observer = PaneTouchObserverView()
        window.addSubview(observer)
        #expect(observer.recognizer.view === window)

        PaneTouchObserver.dismantleUIView(observer, coordinator: ())

        #expect(observer.recognizer.view == nil)
    }

    @Test
    func touchDownsReachTheCurrentHandler() {
        let observer = PaneTouchObserverView()
        var reported: [CGPoint] = []
        observer.onTouchDown = { reported.append($0) }

        observer.recognizer.onTouchDown?(CGPoint(x: 12, y: 34))

        #expect(reported == [CGPoint(x: 12, y: 34)])
    }
}
#endif
