import SwiftUI

/// Provides Dynamic Type aware font helpers that map existing fixed sizes onto
/// preferred text styles so the UI scales with user accessibility settings.
extension Font {
    static func bitchatSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let style = Font.TextStyle.bitchatPreferredStyle(for: size)
        var font = Font.system(style, design: design)
        if weight != .regular {
            font = font.weight(weight)
        }
        return font
    }
}

private extension Font.TextStyle {
    static func bitchatPreferredStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5:
            return .caption2
        case ..<13.0:
            return .caption
        case ..<14.0:
            return .footnote
        case ..<16.5:
            return .body
        case ..<19.0:
            return .title3
        case ..<23.0:
            return .title2
        case ..<30.0:
            return .title
        default:
            return .largeTitle
        }
    }
}
