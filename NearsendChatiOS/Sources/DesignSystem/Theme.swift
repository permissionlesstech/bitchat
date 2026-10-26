import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    static func adaptive(day: Color, night: Color) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(night) : UIColor(day) })
    }
}

/// Design tokens from nearsend.app ("The Open Sky"): frosted glass over a day/night sky, one action blue, navy ink.
enum Theme {
    static let actionBlue = Color(hex: 0x2F6FE0)
    static let actionBlueDeep = Color(hex: 0x2459C0)
    static let brandBlue = Color(hex: 0x3F7FE8)
    static let nightBlue = Color(hex: 0xB7D2FF)
    static let skyPill = Color(hex: 0x0E2855, opacity: 0.65)

    static let ink = Color.adaptive(day: Color(hex: 0x1B2A4A), night: Color(hex: 0xEAF2FF))
    static let inkSecondary = Color.adaptive(day: Color(hex: 0x1B2A4A, opacity: 0.62), night: Color(hex: 0xEAF2FF, opacity: 0.62))
    static let link = Color.adaptive(day: actionBlueDeep, night: nightBlue)
    static let secure = Color.adaptive(day: Color(hex: 0x0F6B3F), night: Color(hex: 0x6EE7B7))

    static let glassFill = Color.adaptive(day: Color.white.opacity(0.84), night: Color(hex: 0x0C1A36, opacity: 0.74))
    static let glassEdge = Color.adaptive(day: Color.white.opacity(0.95), night: Color.white.opacity(0.14))
    static let glassShadow = Color.adaptive(day: Color(hex: 0x143C78, opacity: 0.20), night: Color.black.opacity(0.35))

    static func display(_ size: CGFloat) -> Font { .custom("Anton-Regular", size: size) }

    static let rCard: CGFloat = 24
    static let rField: CGFloat = 16
    static let rButton: CGFloat = 12
}

struct SkyBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            if scheme == .dark {
                LinearGradient(colors: [Color(hex: 0x040B1F), Color(hex: 0x0A1C47), Color(hex: 0x2B4A86)], startPoint: .top, endPoint: .bottom)
                Canvas { ctx, size in
                    for i in 0..<80 {
                        let x = frac(sin(Double(i) * 12.9898) * 43758.5453) * size.width
                        let y = frac(sin(Double(i) * 78.233) * 12543.123) * size.height * 0.8
                        let r = 0.6 + frac(sin(Double(i) * 3.7) * 9999) * 1.2
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                                 with: .color(.white.opacity(0.35 + frac(sin(Double(i)) * 777) * 0.5)))
                    }
                }
            } else {
                LinearGradient(stops: [.init(color: Color(hex: 0x356CB5), location: 0), .init(color: Color(hex: 0x6D9BD6), location: 0.45),
                                       .init(color: Color(hex: 0xA9C4E6), location: 0.8), .init(color: Color(hex: 0xECD2B0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                cloud(w: 260, h: 70, x: drift ? -70 : -110, y: -230)
                cloud(w: 320, h: 86, x: drift ? 120 : 80, y: -40)
                cloud(w: 240, h: 64, x: drift ? -40 : -90, y: 220)
            }
        }
        .ignoresSafeArea()
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) { drift = true } } }
    }

    private func frac(_ v: Double) -> Double { v - floor(v) }
    private func cloud(w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Ellipse().fill(.white.opacity(0.32)).frame(width: w, height: h).blur(radius: 22).offset(x: x, y: y)
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat = Theme.rCard
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Theme.glassFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.glassEdge, lineWidth: 1))
            .shadow(color: Theme.glassShadow, radius: 18, y: 10)
    }
}
extension View { func glass(radius: CGFloat = Theme.rCard) -> some View { modifier(Glass(radius: radius)) } }

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View { content.padding(padding).glass().foregroundStyle(Theme.ink) }
}

/// Page titles sit straight on the sky in the poster face.
struct PageTitle: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).textCase(.uppercase).font(Theme.display(40)).foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
            .shadow(color: Color(hex: 0x0C2444, opacity: 0.35), radius: 8, y: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text that must read directly on the sky goes on the dark-blue pill.
struct SkyPill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12)
            .background(Theme.skyPill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct PrimaryButton: View {
    let title: LocalizedStringKey
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(LinearGradient(colors: [Theme.actionBlue, Theme.actionBlueDeep], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: Theme.rButton, style: .continuous))
            .shadow(color: Theme.actionBlue.opacity(0.4), radius: 14, y: 6)
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 48
    var online = false
    private var shade: Double { Double(abs(name.hashValue) % 5) / 10 }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(LinearGradient(colors: [Theme.brandBlue.opacity(1 - shade * 0.3), Theme.actionBlueDeep], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white))
            if online {
                Circle().fill(Color(hex: 0x1F7A4D)).frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
    }
}

/// Green is reserved for "connected" and "secure".
struct StatusPill: View {
    let text: LocalizedStringKey
    var color: Color = Theme.secure
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
    }
}
