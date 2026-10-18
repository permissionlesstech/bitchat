import SwiftUI

struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0
    @State private var pulse = false

    private let pages: [(icon: String, title: String, body: String)] = [
        ("antenna.radiowaves.left.and.right", "Chat without internet", "Messages hop phone to phone over Bluetooth. No signal, no SIM, no account."),
        ("point.3.connected.trianglepath.dotted", "Every phone is a relay", "The more people nearby, the further your message travels."),
        ("lock.shield.fill", "Private by design", "Direct messages are end-to-end encrypted. Nothing is stored on a server."),
    ]

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                HStack { Spacer(); StatusPill(text: "Early development", color: Theme.warn) }.padding(.horizontal, 24).padding(.top, 8)
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 28) {
                            ZStack {
                                ForEach(0..<3) { r in
                                    Circle().stroke(Theme.mint.opacity(0.25 - Double(r) * 0.07), lineWidth: 1)
                                        .frame(width: 120 + CGFloat(r) * 50, height: 120 + CGFloat(r) * 50)
                                        .scaleEffect(pulse ? 1.12 : 0.95)
                                        .animation(.easeInOut(duration: 2.2).repeatForever().delay(Double(r) * 0.25), value: pulse)
                                }
                                Image(systemName: pages[i].icon)
                                    .font(.system(size: 54, weight: .light))
                                    .foregroundStyle(Theme.accent)
                            }.frame(height: 260)
                            VStack(spacing: 12) {
                                Text(pages[i].title).font(.system(size: 30, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                                Text(pages[i].body).font(.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                            }.padding(.horizontal, 32)
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
