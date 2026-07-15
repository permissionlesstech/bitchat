import SwiftUI

/// IRC-flavored toggle: the whole row is one button and the state is spelled
/// out as an on/off pill instead of a system switch. Shared by the settings
/// surfaces (App Info's connectivity toggles and friends).
struct IRCToggleStyle: ToggleStyle {
    let accent: Color
    let onLabel: LocalizedStringKey
    let offLabel: LocalizedStringKey

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 12) {
                configuration.label
                Spacer()
                Text(configuration.isOn ? onLabel : offLabel)
                    .textCase(.uppercase)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(configuration.isOn ? accent : .secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(accent.opacity(configuration.isOn ? 0.18 : 0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(accent.opacity(configuration.isOn ? 0.35 : 0.15), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
