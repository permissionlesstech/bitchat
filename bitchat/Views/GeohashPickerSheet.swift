import SwiftUI

struct GeohashPickerSheet: View {
    @Binding var isPresented: Bool
    let onGeohashSelected: (String) -> Void
    @State private var selectedGeohash: String = ""
    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Selected geohash display
                HStack {
                    Text(selectedGeohash.isEmpty ? "pan and zoom to select" : "#\(selectedGeohash)")
                        .font(.bitchatSystem(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("select") {
                        if !selectedGeohash.isEmpty {
                            onGeohashSelected(selectedGeohash)
                        }
                    }
                    .font(.bitchatSystem(size: 14, design: .monospaced))
                    .foregroundColor(selectedGeohash.isEmpty ? Color.secondary : textColor)
                    .disabled(selectedGeohash.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(backgroundColor.opacity(0.1))
                .cornerRadius(8)
            
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(backgroundColor.opacity(0.95))

                Divider()

                // Map view (Leaflet-based, same as Android)
                GeohashMapView(selectedGeohash: $selectedGeohash)
            }
            .background(backgroundColor)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            #else
            .navigationTitle("")
            #endif
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        #if os(macOS)
        .frame(minWidth: 800, idealWidth: 1200, maxWidth: .infinity, minHeight: 600, idealHeight: 800, maxHeight: .infinity)
        #endif
        .background(backgroundColor)
    }
}

#Preview {
    GeohashPickerSheet(
        isPresented: .constant(true),
        onGeohashSelected: { _ in }
    )
}
