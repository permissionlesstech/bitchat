import SwiftUI

struct GeohashPickerSheet: View {
    @Binding var isPresented: Bool
    let onGeohashSelected: (String) -> Void
    let initialGeohash: String
    @State private var selectedGeohash: String = ""
    @State private var currentPrecision: Int? = 6
    @Environment(\.colorScheme) var colorScheme

    init(isPresented: Binding<Bool>, initialGeohash: String = "", onGeohashSelected: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self.initialGeohash = initialGeohash
        self.onGeohashSelected = onGeohashSelected
        self._selectedGeohash = State(initialValue: initialGeohash)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    private enum Strings {
        static let instruction = String(localized: "geohash_picker.instruction", comment: "Instruction text for geohash map picker")
        static let selectButton = String(localized: "geohash_picker.select_button", comment: "Select button text in geohash picker")
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }

    var body: some View {
        ZStack {
            // Full-screen map
            GeohashMapView(
                selectedGeohash: $selectedGeohash,
                initialGeohash: initialGeohash,
                showFloatingControls: false,
                precision: $currentPrecision
            )
            .ignoresSafeArea()

            // Top instruction banner
            VStack {
                HStack {
                    Text(Strings.instruction)
                        .font(.bitchatSystem(size: 14, design: .monospaced))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white.opacity(0.95))
                                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                        )
                }
                .padding(.horizontal, 16)
                .padding(.top, 20) // Smaller top padding and more on top
                Spacer()
            }

            // Current geohash display
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("#\(selectedGeohash.isEmpty ? "" : selectedGeohash)")
                        .font(.bitchatSystem(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white.opacity(0.95))
                                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                        )
                    Spacer()
                }
                .padding(.bottom, 120) // Position geohash display a bit down
            }

            // Bottom controls bar
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    // Minus button
                    Button(action: {
                        if let precision = currentPrecision, precision > 1 {
                            currentPrecision = precision - 1
                        }
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor((currentPrecision ?? 6) <= 1 ? Color.secondary : textColor)
                            .frame(width: 60, height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 25)
                                    .fill(textColor.opacity(0.15))
                                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                            )
                    }
                    .disabled((currentPrecision ?? 6) <= 1)

                    // Plus button
                    Button(action: {
                        if let precision = currentPrecision, precision < 12 {
                            currentPrecision = precision + 1
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor((currentPrecision ?? 6) >= 12 ? Color.secondary : textColor)
                            .frame(width: 60, height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 25)
                                    .fill(textColor.opacity(0.15))
                                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                            )
                    }
                    .disabled((currentPrecision ?? 6) >= 12)

                    // Select button
                    Button(action: {
                        if !selectedGeohash.isEmpty {
                            onGeohashSelected(selectedGeohash)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                            Text(Strings.selectButton)
                                .font(.bitchatSystem(size: 14, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(selectedGeohash.isEmpty ? Color.secondary : Color.secondary)
                        .frame(minWidth: 100, minHeight: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 25)
                                .fill(Color.secondary.opacity(0.15))
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        )
                    }
                    .disabled(selectedGeohash.isEmpty)
                    .opacity(selectedGeohash.isEmpty ? 0.6 : 1.0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40) // Move buttons more up in the screen
            }
        }
        .background(backgroundColor)
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
        .onAppear {
            // Always sync selectedGeohash with initialGeohash when view appears
            // This ensures we restore the last selected geohash from LocationChannelsSheet
            if !initialGeohash.isEmpty {
                selectedGeohash = initialGeohash
                currentPrecision = initialGeohash.count
            }
        }
    }
}

#Preview {
    GeohashPickerSheet(
        isPresented: .constant(true),
        initialGeohash: "",
        onGeohashSelected: { _ in }
    )
}
