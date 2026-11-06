#if os(macOS)
import AppKit
import BitFoundation
import SwiftUI
import XCTest
@testable import bitchat

// Mounted production composer with synthetic models and native in-process events.
// The declared test host enables non-hit-testing frame probes at compile time.
// Attachment checks the binding; it does not open NSOpenPanel. This does not
// exercise physical input, VoiceOver, or microphone/camera capture.


@MainActor
private final class MacButtonState: ObservableObject {
    @Published var text = "hello"
    @Published var picker = false
    var pickerRequests = 0
    var sent: [String] = []
    var frames: [String: CGRect] = [:]
    var timer: Timer?
    let voice = VoiceRecordingViewModel()

    init() {
        // A mistaken hit on the empty-draft microphone cannot request permission.
        voice.sessionProvider = { MacButtonCapture() }
    }
}

@MainActor
private final class MacButtonCapture: VoiceCaptureSession {
    var isLive: Bool { false }
    func requestPermission() async -> Bool { true }
    func start() async throws {}
    func finish() async -> URL? { nil }
    func cancel() async {}
    func panicCancelSynchronously() {}
}

@MainActor
private struct MacButtonFixture: View {
    @ObservedObject var state: MacButtonState
    @FocusState private var focused: Bool

    var body: some View {
        ContentComposerView(
            messageText: $state.text,
            isTextFieldFocused: $focused,
            voiceRecordingVM: state.voice,
            autocompleteDebounceTimer: Binding(
                get: { state.timer }, set: { state.timer = $0 }
            ),
            onSendMessage: {
                state.sent.append(state.text)
                state.text = ""
            },
            showMacImagePicker: Binding(
                get: { state.picker },
                set: {
                    state.picker = $0
                    if $0 { state.pickerRequests += 1 }
                }
            )
        )
    }
}

final class MacButtonTests: XCTestCase {
    @MainActor func testMatrixNarrowButtons() throws {
        try checkButtons(glass: false, large: false, width: 280)
    }

    @MainActor func testGlassNarrowButtons() throws {
        try checkButtons(glass: true, large: false, width: 280)
    }

    @MainActor func testMatrixLargeButtons() throws {
        try checkButtons(glass: false, large: true, width: 390)
    }

    @MainActor func testGlassLargeButtons() throws {
        try checkButtons(glass: true, large: true, width: 390)
    }

    @MainActor private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func waitFor(_ predicate: () -> Bool, message: String) throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline { pump() }
        XCTAssertTrue(predicate(), message)
        guard predicate() else { throw ProbeError.condition(message) }
    }

    private enum ProbeError: Error {
        case condition(String)
    }

    @MainActor private func checkButtons(glass: Bool, large: Bool, width: CGFloat) throws {
        continueAfterFailure = false
        _ = NSApplication.shared
        let state = MacButtonState()
        let viewModel = makeLayoutViewModel().viewModel
        let models = makeLayoutFeatureModels(for: viewModel)
        let height: CGFloat = 180
        let root = installLayoutEnvironment(MacButtonFixture(state: state), featureModels: models)
            .environment(\.appTheme, glass ? .liquidGlass : .matrix)
            .environment(\.dynamicTypeSize, large ? .accessibility5 : .large)
            .frame(width: width, height: height, alignment: .top)
            .coordinateSpace(name: "LocalComposerProbe")
            .onPreferenceChange(LocalComposerProbeFrames.self) { state.frames = $0 }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            state.timer?.invalidate()
            window.orderOut(nil)
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try waitFor({ state.frames["attachment"] != nil && state.frames["action"] != nil },
                    message: "Mounted full composer must report both control frames")

        func measuredFrame(_ key: String) throws -> CGRect {
            let rect = try XCTUnwrap(state.frames[key], "Missing measured frame: \(key)")
            XCTAssertFalse(rect.isEmpty)
            XCTAssertFalse(rect.isInfinite)
            XCTAssertFalse(rect.isNull)
            XCTAssertGreaterThanOrEqual(rect.minX, -1)
            XCTAssertGreaterThanOrEqual(rect.minY, -1)
            XCTAssertLessThanOrEqual(rect.maxX, width + 1)
            XCTAssertLessThanOrEqual(rect.maxY, height + 1)
            return rect
        }

        func click(_ key: String) throws {
            let rect = try measuredFrame(key)
            // SwiftUI's named coordinate space is top-left based. NSHostingView
            // flipping determines the corresponding native view-space point.
            let y = host.isFlipped ? rect.midY : host.bounds.height - rect.midY
            let point = host.convert(NSPoint(x: rect.midX, y: y), to: nil)
            let stamp = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: stamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1
            ))
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: stamp + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                clickCount: 1, pressure: 0
            ))
            // Deliver both events directly; this XCTest host does not run the
            // usual application event dispatcher. The runner bounds tracking hangs.
            window.sendEvent(down)
            window.sendEvent(up)
            print("MAC_NATIVE_CLICK key=\(key) rect=\(rect) hostFlipped=\(host.isFlipped) windowPoint=\(point) keyWindow=\(window.isKeyWindow) applicationActive=\(NSApp.isActive) directPair=true")
            pump(0.15)
        }

        let attachment = try measuredFrame("attachment")
        let action = try measuredFrame("action")
        XCTAssertFalse(attachment.intersects(action), "Measured composer control frames must not overlap")
        print("MAC_BUTTON_FRAMES glass=\(glass) large=\(large) width=\(width) attachment=\(attachment) action=\(action)")
        XCTAssertEqual(state.sent, [])
        try click("attachment")
        try waitFor({ state.pickerRequests == 1 }, message: "Native attachment click must set the real picker binding")
        XCTAssertTrue(state.picker)
        XCTAssertEqual(state.sent, [], "Attachment must not send the draft")

        state.picker = false
        try click("action")
        try waitFor({ state.sent == ["hello"] }, message: "Native send click must invoke the real send callback exactly once")
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(state.pickerRequests, 1, "Send must not activate attachment")

        viewModel.activeChannel = .location(GeohashChannel(level: .block, geohash: "s000000"))
        try waitFor({ !models.conversationUIModel.canSendMediaInCurrentContext && state.frames["attachment"] == nil },
                    message: "No-media context must remove attachment before probing disabled send")
        XCTAssertEqual(state.text, "")
        try click("action")
        pump(0.2)
        XCTAssertEqual(state.sent, ["hello"], "Empty no-media send must not invoke its callback")
        XCTAssertEqual(state.text, "")

        state.text = "again"
        pump(0.15)
        try click("action")
        try waitFor({ state.sent == ["hello", "again"] },
                    message: "The same no-media send control must work after the draft becomes nonempty")
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(state.pickerRequests, 1)
        print("MAC_FULL_ROW_BUTTON_PASS glass=\(glass) large=\(large) width=\(width): in-process native attachment/send/disabled-send events with non-hit-testing frame probes; no physical input or VoiceOver claim")
    }
}
#endif
