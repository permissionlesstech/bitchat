#if COMPOSER_TEST_HOST
import SwiftUI

// Compiled only into the inert composer host, never the shipping app.
struct LocalComposerProbeFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LocalComposerProbeStateKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var localComposerProbeState: String {
        get { self[LocalComposerProbeStateKey.self] }
        set { self[LocalComposerProbeStateKey.self] = newValue }
    }
}

private struct LocalComposerFrameProbe: View {
    let name: String
    @Environment(\.localComposerProbeState) private var state

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: LocalComposerProbeFrames.self,
                value: [state + name: geometry.frame(in: .named("LocalComposerProbe"))]
            )
        }.allowsHitTesting(false)
    }
}

extension View {
    func localComposerProbeFrame(_ name: String) -> some View {
        background(LocalComposerFrameProbe(name: name))
    }
}
#endif
