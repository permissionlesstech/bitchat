//
//  Fonts.swift
//  bitchat
//
//  Created by Tim Johnsen on 7/29/25.
//

import UIKit
import SwiftUI

extension Font {
    static func scalableMonospaced(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .caption
    ) -> Font {
#if os(iOS)
        let baseFont = UIFont.monospacedSystemFont(ofSize: size, weight: weight.toUIFontWeight())
        let scaledFont = UIFontMetrics(forTextStyle: textStyle.toUIFontTextStyle())
            .scaledFont(for: baseFont)
        return Font(scaledFont)
#else
        // macOS: dynamic type isn't supported the same way, return plain monospaced font
        return .system(size: size, weight: weight, design: .monospaced)
#endif
    }
}

#if os(iOS)
import UIKit

private extension Font.Weight {
    func toUIFontWeight() -> UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

private extension Font.TextStyle {
    func toUIFontTextStyle() -> UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
}
#endif
