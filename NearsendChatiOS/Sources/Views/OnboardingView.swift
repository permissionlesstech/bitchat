import SwiftUI

struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [(icon: String, title: LocalizedStringKey, body: LocalizedStringKey)] = [
        ("antenna.radiowaves.left.and.right", "Chat without internet", "Messages hop phone to phone over Bluetooth. No signal, no SIM, no account."),
        ("point.3.connected.trianglepath.dotted", "Every phone is a relay", "The more people nearby, the further your message travels."),
        ("lock.shield.fill", "Private by design", "Direct messages are end-to-end encrypted. Nothing is stored on a server."),
    ]

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 0) {
                HStack {
                    Text(verbatim: "NEARSEND").font(Theme.display(22)).foregroundStyle(.white)
                    Spacer()
                    SkyPill { Text("Early development").font(.caption.weight(.medium)) }.scaleEffect(0.85, anchor: .trailing)
                }.padding(.horizontal, 24).padding(.top, 8)
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 28) {
                            ZStack {
                                ForEach(0..<3) { r in
                                    Circle().stroke(.white.opacity(0.5 - Double(r) * 0.14), lineWidth: 1)
                                        .frame(width: 130 + CGFloat(r) * 56, height: 130 + CGFloat(r) * 56)
                                        .scaleEffect(pulse ? 1.1 : 0.95)
                                        .animation(reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever().delay(Double(r) * 0.25), value: pulse)
                                }
                                Image(systemName: pages[i].icon).font(.system(size: 46, weight: .regular))
                                    .foregroundStyle(Theme.actionBlue)
                                    .frame(width: 112, height: 112)
                                    .glass(radius: 56)
                            }.frame(height: 270).accessibilityHidden(true)
                            VStack(spacing: 16) {
                                Text(pages[i].title).textCase(.uppercase).font(Theme.display(40)).foregroundStyle(.white)
                                    .multilineTextAlignment(.center).shadow(color: Color(hex: 0x0C2444, opacity: 0.35), radius: 8, y: 2)
                                    .accessibilityAddTraits(.isHeader)
                                SkyPill { Text(pages[i].body).font(.body.weight(.medium)).multilineTextAlignment(.center) }
                            }.padding(.horizontal, 24)
                        }.tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                PrimaryButton(title: page == pages.count - 1 ? "Allow Bluetooth & start" : "Continue") {
                    if page == pages.count - 1 { done() } else { withAnimation { page += 1 } }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .onAppear { pulse = true }
    }
}
