import Foundation
import Testing
@testable import bitchat

struct PeerColorContrastTests {
    /// Converts HSB (0...1) to sRGB (0...1) and computes WCAG 2.1 contrast ratio against pure black.
    private func contrastAgainstBlack(hue: Double, saturation: Double, brightness: Double) -> Double {
        let h = (hue - floor(hue)) * 6.0
        let i = Int(floor(h)) % 6
        let f = h - floor(h)
        let p = brightness * (1.0 - saturation)
        let q = brightness * (1.0 - f * saturation)
        let t = brightness * (1.0 - (1.0 - f) * saturation)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
        return (luminance + 0.05) / 0.05
    }

    @Test func darkModePurpleAndBlueHuesMeetWCAGAAAgainstBlack() {
        for deg in stride(from: 210, through: 306, by: 6) {
            let hue = Double(deg) / 360.0
            let adjusted = PeerColorContrast.adjustForDarkMode(hue: hue, saturation: 0.85, brightness: 0.75)
            let ratio = contrastAgainstBlack(hue: hue, saturation: adjusted.saturation, brightness: adjusted.brightness)
            #expect(ratio >= 4.5, "Hue \(deg)° contrast \(ratio) should be >= 4.5 on black")
        }
    }

    @Test func nonBluePurpleHuesRemainUnchanged() {
        let adjusted = PeerColorContrast.adjustForDarkMode(hue: 0.33, saturation: 0.80, brightness: 0.75)
        #expect(adjusted.saturation == 0.80)
        #expect(adjusted.brightness == 0.75)
    }
}
