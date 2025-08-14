//
//  MessageBubble.swift
//  bitchat
//
//  Created by Waluya Juang Husada on 08/08/25.
//

import SwiftUI

enum BubbleSide { case left, right }

struct BubbleShape: Shape {
    let side: BubbleSide
    let radius: CGFloat = 18
    let tailSize: CGSize = .init(width: 6, height: 10)

    func path(in rect: CGRect) -> Path {
        var r = rect
        // Leave space for the tail
        switch side {
        case .left:  r.origin.x += tailSize.width; r.size.width -= tailSize.width
        case .right: r.size.width -= tailSize.width
        }

        var p = Path(roundedRect: r, cornerRadius: radius)

        // Tail
        let y = r.maxY - 10
        switch side {
        case .left:
            p.move(to: .init(x: r.minX, y: y))
            p.addLine(to: .init(x: r.minX - tailSize.width, y: y + tailSize.height/2))
            p.addLine(to: .init(x: r.minX, y: y + tailSize.height))
            p.closeSubpath()
        case .right:
            p.move(to: .init(x: r.maxX, y: y))
            p.addLine(to: .init(x: r.maxX + tailSize.width, y: y + tailSize.height/2))
            p.addLine(to: .init(x: r.maxX, y: y + tailSize.height))
            p.closeSubpath()
        }
        return p
    }
}

struct MessageBubble: ViewModifier {
    let isOutgoing: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let side: BubbleSide = isOutgoing ? .right : .left
        let fill: Color = {
            if isOutgoing { return Color.accentColor } // iMessage blue-ish if you set Accent
            return scheme == .dark ? Color(white: 0.15) : Color(white: 0.93)
        }()
        let text: Color = isOutgoing ? .white : .primary
        let stroke = fill.opacity(isOutgoing ? 0.0 : (scheme == .dark ? 0.2 : 0.35))

        content
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundStyle(text)
            .background(
                BubbleShape(side: side)
                    .fill(fill)
            )
            .overlay(
                BubbleShape(side: side)
                    .stroke(stroke, lineWidth: isOutgoing ? 0 : 0.5)
            )
            .compositingGroup() // keeps crisp edges with tail
    }
}

extension View {
    func messageBubble(isOutgoing: Bool) -> some View {
        modifier(MessageBubble(isOutgoing: isOutgoing))
    }
}
