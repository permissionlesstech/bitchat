import SwiftUI

struct ChatScreen<Header: View, Messages: View, Composer: View>: View {
    let backgroundColor: Color

    private let header: Header
    private let messages: Messages
    private let composer: Composer

    init(
        backgroundColor: Color,
        @ViewBuilder header: () -> Header,
        @ViewBuilder messages: () -> Messages,
        @ViewBuilder composer: () -> Composer
    ) {
        self.backgroundColor = backgroundColor
        self.header = header()
        self.messages = messages()
        self.composer = composer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    messages
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            Divider()
            composer
        }
        .background(backgroundColor)
    }
}

struct MessageListView<Content: View>: View {
    let backgroundColor: Color

    private let content: Content

    init(backgroundColor: Color, @ViewBuilder content: () -> Content) {
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        content
            .background(backgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ComposerView<Content: View>: View {
    let backgroundColor: Color

    private let content: Content

    init(backgroundColor: Color, @ViewBuilder content: () -> Content) {
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .background(backgroundColor.opacity(0.95))
    }
}

struct PeopleSheetView<Content: View>: View {
    let backgroundColor: Color
    let textColor: Color

    private let content: Content

    init(
        backgroundColor: Color,
        textColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
#if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
#endif
    }
}

struct PrivateHeaderView<Content: View>: View {
    let height: CGFloat
    let backgroundColor: Color
    let textColor: Color
    let backAccessibilityLabel: String
    let closeAccessibilityLabel: String
    let onBack: () -> Void
    let onClose: () -> Void

    private let content: Content

    init(
        height: CGFloat,
        backgroundColor: Color,
        textColor: Color,
        backAccessibilityLabel: String,
        closeAccessibilityLabel: String = "Close",
        onBack: @escaping () -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.height = height
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.backAccessibilityLabel = backAccessibilityLabel
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self.onBack = onBack
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.bitchatSystem(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(backAccessibilityLabel)

            Spacer(minLength: 0)

            content
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeAccessibilityLabel)
        }
        .frame(height: height)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(backgroundColor)
    }
}
