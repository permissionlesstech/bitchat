import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var store: ChatStore

    var body: some View {
        NavigationStack {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        PageTitle(text: "You").padding(.top, 8)
                        Card {
                            VStack(spacing: 12) {
                                Avatar(name: store.nickname, size: 88)
                                TextField("Nickname", text: $store.nickname)
                                    .multilineTextAlignment(.center)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                StatusPill(text: "No account · no phone number")
                            }.frame(maxWidth: .infinity)
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Your fingerprint", systemImage: "key.fill").font(.subheadline.weight(.semibold))
                                Text("A3F1 9C02 7BD4 E58A\n11C0 4F6E 92AB 3D77")
                                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.link)
                                Text("Compare this in person to verify a contact. Placeholder until keys are generated on device.")
                                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SkyPill {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Project status", systemImage: "hammer.fill").font(.subheadline.weight(.semibold))
                                Text("Early development. Shows simulated peers. Not security audited. Bitchat compatibility unverified. GPL-3.0.")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.85))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
