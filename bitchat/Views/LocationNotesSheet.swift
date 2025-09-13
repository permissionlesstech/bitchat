import SwiftUI

struct LocationNotesSheet: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject private var locationManager = LocationChannelManager.shared
    @Binding var notesGeohash: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColor: Color { colorScheme == .dark ? .black : .white }
    private var textColor: Color { colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0) }
    private var secondaryTextColor: Color { textColor.opacity(0.8) }

    var body: some View {
        Group {
            if let gh = notesGeohash ?? locationManager.availableChannels.first(where: { $0.level == .block })?.geohash {
                // Found block geohash: show notes view
                LocationNotesView(geohash: gh)
                    .environmentObject(viewModel)
            } else {
                // Acquire location: keep a loading overlay (Matrix) until we either get a block geohash
                ZStack {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("notes")
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                Text("acquiring location…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(secondaryTextColor)
                            }
                            Spacer()
                            Button(action: { dismiss() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(textColor)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close")
                        }
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                        .background(backgroundColor.opacity(0.95))
                        Spacer()
                    }
                    MatrixRainView()
                        .transition(.opacity)
                }
                .background(backgroundColor)
                .foregroundColor(textColor)
                .onAppear {
                    LocationChannelManager.shared.enableLocationChannels()
                    // Nudge a fresh fix
                    LocationChannelManager.shared.refreshChannels()
                }
                .onChange(of: locationManager.availableChannels) { channels in
                    if notesGeohash == nil, let block = channels.first(where: { $0.level == .block }) {
                        notesGeohash = block.geohash
                    }
                }
            }
        }
    }
}
