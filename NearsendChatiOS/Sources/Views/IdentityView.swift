import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var store: ChatStore
    @State private var confirmWipe = false

    var body: some View {
        NavigationStack {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        PageTitle(text: "You").padding(.top, 8)
                            .onTapGesture(count: 3) { confirmWipe = true }   // panic: triple-tap
                        Card {
                            VStack(spacing: 12) {
                                Avatar(name: store.nickname, size: 88).accessibilityHidden(true)
                                TextField("Nickname", text: $store.nickname)
                                    .multilineTextAlignment(.center)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .submitLabel(.done)
                                    .onSubmit { store.applyNickname() }
                                StatusPill(text: "No account · no phone number")
                            }.frame(maxWidth: .infinity)
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Your fingerprint", systemImage: "key.fill").font(.subheadline.weight(.semibold))
                                Text(verbatim: store.myFingerprint.isEmpty ? "—" : store.myFingerprint)
                                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.link)
                                Text("Compare this in person to verify a contact. It changes if you erase everything.")
                                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(role: .destructive) { confirmWipe = true } label: {
                            Label("Erase everything", systemImage: "trash.fill").font(.subheadline.weight(.semibold))
                                .foregroundStyle(.red).frame(maxWidth: .infinity).padding(.vertical, 14).glass(radius: Theme.rButton)
                        }
                        SkyPill {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Project status", systemImage: "hammer.fill").font(.subheadline.weight(.semibold))
                                Text("Early development. Not security audited. Not tested on many devices yet. Bitchat compatibility unverified. GPL-3.0.")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.85))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Erase all messages, keys and settings on this phone?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) { store.wipeAll() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This cannot be undone. You will get a new identity.") }
        }
    }
}
