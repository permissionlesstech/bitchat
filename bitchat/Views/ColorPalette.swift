
//
//  ColorPalette.swift
//  bitchat
//
//  Created by Gemini on 7/9/25.
//

import SwiftUI

struct ColorPalette {
    let backgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color

    static func forColorScheme(_ colorScheme: ColorScheme) -> ColorPalette {
        if colorScheme == .dark {
            return ColorPalette(
                backgroundColor: .black,
                textColor: .green,
                secondaryTextColor: Color.green.opacity(0.8)
            )
        } else {
            return ColorPalette(
                backgroundColor: .white,
                textColor: Color(red: 0, green: 0.5, blue: 0),
                secondaryTextColor: Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
            )
        }
    }
}
