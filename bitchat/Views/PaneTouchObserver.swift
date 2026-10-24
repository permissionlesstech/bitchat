//
// PaneTouchObserver.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)
import SwiftUI
// UIKit itself comes with SwiftUI; the subclass interface (touch handling,
// the settable state) is its own submodule.
import UIKit.UIGestureRecognizerSubclass

/// Reports where each touch goes down in the window, so the split layout
/// can tell which pane was touched last (E1). It watches from the window
/// rather than from the panes: a gesture on the panes' own views (a drag,
/// or a simultaneous gesture on a scroll view) competes with theirs, while
/// the window's recognizer here fails at every touch-down, so it never
/// blocks, delays or cancels any other gesture.
///
/// Known limitation: VoiceOver's navigation delivers no touches. Swiping
/// from element to element, or a three-finger scroll, in a pane doesn't
/// make it the last touched; what VoiceOver activates still moves the
/// focus through E1's semantic overrides (a composer taking the keyboard
/// or typed in, a people button, the trailing badge, a picker choice, a DM
/// opening). VoiceOver's own focus changes
/// (`UIAccessibility.elementFocusedNotification`) are deliberately not
/// mapped onto the panes: VoiceOver also moves its cursor by itself, after
/// content and layout changes and as presentations close, and nothing
/// tells those moves from a person's swipe. A fold would then park the pane
/// the person was in (E3).
struct PaneTouchObserver: UIViewRepresentable {
    /// A touch went down at this point, in window coordinates.
    let onTouchDown: (CGPoint) -> Void

    func makeUIView(context: Context) -> PaneTouchObserverView {
        let view = PaneTouchObserverView()
        view.onTouchDown = onTouchDown
        return view
    }

    func updateUIView(_ view: PaneTouchObserverView, context: Context) {
        view.onTouchDown = onTouchDown
    }

    static func dismantleUIView(_ view: PaneTouchObserverView, coordinator: ()) {
        view.uninstall()
    }
}

/// Keeps the observer's recognizer on whichever window this view is in. The
/// view itself takes no touches and has nothing to say to VoiceOver. A touch
/// on something the window presents over its content (a sheet, a popover,
/// an alert or dialog, a full-screen cover) is a touch on that, not on the
/// content, so it isn't reported.
final class PaneTouchObserverView: UIView {
    var onTouchDown: ((CGPoint) -> Void)?

    let recognizer = PassiveTouchDownRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        recognizer.onTouchDown = { [weak self] point in
            guard let self, !self.isWindowPresenting else { return }
            self.onTouchDown?(point)
        }
    }

    /// The window's root presents something over the content. Every
    /// presentation from the content's tree goes through the root.
    private var isWindowPresenting: Bool {
        window?.rootViewController?.presentedViewController != nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        install(on: window)
    }

    /// Takes the recognizer off the window it watches.
    func uninstall() {
        install(on: nil)
    }

    private func install(on window: UIWindow?) {
        guard recognizer.view !== window else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        window?.addGestureRecognizer(recognizer)
    }
}

/// Sees every touch-down in its view and fails at once, before any other
/// gesture could wait on it: it never recognizes, cancels nothing, delays
/// nothing, and runs alongside every other recognizer.
final class PassiveTouchDownRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// The touch-down point, in window coordinates.
    var onTouchDown: ((CGPoint) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first {
            // nil: the touch's own window's coordinates.
            onTouchDown?(touch.location(in: nil))
        }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
#endif
