import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var store: ChatStore

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 12) {
                            Avatar(name: store.nickname, size: 96)
                            TextField("Nickname", text: $store.nickname)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            StatusPill(text: "No account · no phone number")
                        }.padding(.top, 8)

                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Your fingerprint", systemImage: "key.fill").font(.subheadline.weight(.semibold))
                                Text("A3F1 9C02 7BD4 E58A\n11C0 4F6E 92AB 3D77")
                                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.mint)
                                Text("Compare this in person to verify a contact. Placeholder until keys are generated on device.")
                                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Project status", systemImage: "hammer.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.warn)
                                Text("Early development. Shows simulated peers. Not security audited. Bitchat compatibility unverified. GPL-3.0.")
                                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 20)
                }
            }
            .navigationTitle("You")
        }
    }
}
