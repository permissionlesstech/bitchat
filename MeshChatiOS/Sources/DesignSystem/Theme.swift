import SwiftUI

enum Theme {
    static let bg = Color(red: 0.03, green: 0.04, blue: 0.07)
    static let surface = Color(red: 0.07, green: 0.09, blue: 0.14)
    static let stroke = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let mint = Color(red: 0.20, green: 0.95, blue: 0.75)
    static let cyan = Color(red: 0.25, green: 0.70, blue: 1.0)
    static let violet = Color(red: 0.55, green: 0.40, blue: 1.0)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.25)

    static let accent = LinearGradient(colors: [mint, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let backdrop = LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.12), bg], startPoint: .top, endPoint: .bottom)
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.cyan.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Theme.violet.opacity(0.14), .clear], center: .bottomLeading, startRadius: 0, endRadius: 380)
        }.ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(Theme.accent, in: Capsule())
            .shadow(color: Theme.mint.opacity(0.35), radius: 18, y: 6)
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 48
    var online = false
    private var hue: Double { Double(abs(name.hashValue) % 360) / 360 }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.9), Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.6)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white))
            if online {
                Circle().fill(Theme.mint).frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = Theme.mint
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.25)))
    }
}
