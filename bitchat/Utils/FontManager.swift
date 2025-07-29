//
// FontManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import CoreText

struct FontManager {
    static func registerFonts() {
        let fontNames = [
            "KodeMono-Regular",
            "KodeMono-Medium",
            "KodeMono-SemiBold",
            "KodeMono-Bold"
        ]
        
        for fontName in fontNames {
            registerFont(name: fontName)
        }
    }
    
    private static func registerFont(name: String) {
        guard let fontURL = Bundle.main.url(forResource: name, withExtension: "ttf"),
              let fontDataProvider = CGDataProvider(url: fontURL as CFURL),
              let font = CGFont(fontDataProvider) else {
            print("Failed to load font: \(name)")
            return
        }
        
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(font, &error) {
            if let error = error?.takeRetainedValue() {
                print("Error registering font \(name): \(error)")
            }
        }
    }
    
    enum KodeMonoWeight {
        case regular
        case medium
        case semiBold
        case bold
        
        var fontName: String {
            switch self {
            case .regular:
                return "KodeMono-Regular"
            case .medium:
                return "KodeMono-Medium"
            case .semiBold:
                return "KodeMono-SemiBold"
            case .bold:
                return "KodeMono-Bold"
            }
        }
    }
    
    static func kodeMono(size: CGFloat, weight: KodeMonoWeight = .regular) -> Font {
        return Font.custom(weight.fontName, size: size)
    }
    
    static func kodeMono(_ style: Font.TextStyle, weight: KodeMonoWeight = .regular) -> Font {
        return Font.custom(weight.fontName, size: style.defaultSize)
    }
}

extension Font.TextStyle {
    var defaultSize: CGFloat {
        switch self {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .body:
            return 17
        case .callout:
            return 16
        case .subheadline:
            return 15
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 17
        }
    }
}

extension View {
    func monospaceFont(size: CGFloat, weight: FontManager.KodeMonoWeight = .regular) -> some View {
        self.font(FontManager.kodeMono(size: size, weight: weight))
    }
    
    func monospaceFont(_ style: Font.TextStyle, weight: FontManager.KodeMonoWeight = .regular) -> some View {
        self.font(FontManager.kodeMono(style, weight: weight))
    }
}
