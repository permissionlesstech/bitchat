import SwiftUI

/// Mining body animation: scramble characters (matrix-like) until PoW completes.
struct MiningScrambleText: View {
    let original: String
    let color: Color
    let isSelf: Bool
    let fontSize: CGFloat = 14
    let interval: TimeInterval = 0.06
    @State private var display: String = ""
    @State private var timer: Timer? = nil

    private let charset: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789@#$%&*+-")

    var body: some View {
        Text(display)
            .font(.system(size: fontSize, weight: isSelf ? .bold : .regular, design: .monospaced))
            .foregroundColor(color)
            .onAppear {
                display = scramble(original)
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                    display = scramble(original)
                }
            }
            .onDisappear {
                timer?.invalidate(); timer = nil
            }
}

/// Combined prefix+body single-Text variant to ensure identical wrapping
struct MiningCombinedText: View {
    let prefix: AttributedString
    let original: String
    let color: Color
    let isSelf: Bool
    let fontSize: CGFloat = 14
    let interval: TimeInterval = 0.06
    @State private var display: String = ""
    @State private var timer: Timer? = nil

    private let charset: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789@#$%&*+-")

    var body: some View {
        Text(combinedAttributed)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                display = scramble(original)
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                    display = scramble(original)
                }
            }
            .onDisappear { timer?.invalidate(); timer = nil }
    }

    private var combinedAttributed: AttributedString {
        var res = AttributedString()
        res.append(prefix)
        var style = AttributeContainer()
        style.foregroundColor = color
        style.font = .system(size: fontSize, weight: isSelf ? .bold : .regular, design: .monospaced)
        res.append(AttributedString(display).mergingAttributes(style))
        return res
    }

    private func scramble(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isWhitespace || ch.isNewline { out.append(ch); continue }
            out.append(charset.randomElement() ?? ch)
        }
        return out
    }
}

    private func scramble(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            if ch.isWhitespace || ch.isNewline { out.append(ch); continue }
            out.append(charset.randomElement() ?? ch)
        }
        return out
    }
}
