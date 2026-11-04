#if COMPOSER_TEST_HOST && os(macOS)
import SwiftUI

// Compiled only into the inert composer host, never the shipping app.
struct LocalComposerProbeFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func localComposerProbeFrame(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(
                key: LocalComposerProbeFrames.self,
                value: [name: geometry.frame(in: .named("LocalComposerProbe"))]
            )
        }.allowsHitTesting(false))
    }
}
#endif
