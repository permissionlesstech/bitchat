#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import bitchat

@MainActor
final class ComposerActionFrameTests: XCTestCase {
    private func measure<V: View>(_ view: V, at size: DynamicTypeSize) -> CGSize {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        _ = host.view
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 500, height: 500))
    }

    func testSizingAcrossDynamicType() {
        for size in DynamicTypeSize.allCases {
            let frame = measure(
                Color.clear.modifier(ComposerActionFrame()),
                at: size
            )

            XCTAssertGreaterThanOrEqual(frame.width, 36)
            XCTAssertGreaterThanOrEqual(frame.height, 36)

            if size <= .large {
                XCTAssertEqual(frame.width, 36, accuracy: 0.5)
                XCTAssertEqual(frame.height, 36, accuracy: 0.5)
            }

            for symbol in [
                "camera.circle.fill",
                "mic.circle.fill",
                "arrow.up.circle.fill"
            ] {
                let icon = Image(systemName: symbol)
                    .font(.bitchatSystem(size: 24))
                let natural = measure(icon.fixedSize(), at: size)
                let allocation = measure(
                    icon.modifier(ComposerActionFrame()),
                    at: size
                )
                let context = "\(symbol) at \(size)"

                XCTAssertGreaterThanOrEqual(
                    allocation.width + 0.5,
                    natural.width,
                    "Frame must contain \(context)"
                )
                XCTAssertGreaterThanOrEqual(
                    allocation.height + 0.5,
                    natural.height,
                    "Frame must contain \(context)"
                )

                if size == .accessibility5 {
                    XCTAssertGreaterThan(
                        natural.width, 36,
                        "Fixture must exercise an enlarged icon"
                    )
                    XCTAssertGreaterThan(
                        natural.height, 36,
                        "Fixture must exercise an enlarged icon"
                    )
                }
            }
        }
    }
}
#endif
