//
//  ChatMessage.swift
//  bitchat
//
//  Created by Wentao Guo on 20/08/25.
//


//
//  Chatbox.swift
//  Circle
//
//  Created by Wentao Guo on 20/08/25.
//

import SwiftUI

// MARK: - Model

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let time: Date
    let isMe: Bool
    var delivered: Bool = true
}

// MARK: - Colors

extension Color {
    static let canvasSand   = Color(red: 0.96, green: 0.94, blue: 0.90)
    static let outBubble    = Color.orange.opacity(0.14)
    static let inBubble     = Color.white
    static let inputBG      = Color.white
}

// MARK: - Chat Bubble Shape

struct ChatBubbleShape: Shape {
    var isMe: Bool
    func path(in rect: CGRect) -> Path {
        var r = rect
        let tail: CGFloat = 6
        var path = Path()

        if isMe {
            r.size.width -= tail
            path.addRoundedRect(in: r, cornerSize: .init(width: 12, height: 12))
            
            path.move(to: CGPoint(x: r.maxX, y: r.minY + 10))
            path.addQuadCurve(to: CGPoint(x: r.maxX + tail, y: r.minY + 14),
                              control: CGPoint(x: r.maxX + tail/2, y: r.minY + 6))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY + 18))
            path.closeSubpath()
        } else {
            r.origin.x += tail
            r.size.width -= tail
            path.addRoundedRect(in: r, cornerSize: .init(width: 12, height: 12))
            
            path.move(to: CGPoint(x: r.minX, y: r.minY + 10))
            path.addQuadCurve(to: CGPoint(x: r.minX - tail, y: r.minY + 14),
                              control: CGPoint(x: r.minX - tail/2, y: r.minY + 6))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + 18))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Chat Row

struct ChatRow1: View {
    let msg: ChatMessage
    private let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: msg.isMe ? .trailing : .leading, spacing: 4) {
            
            ZStack(alignment: msg.isMe ? .topTrailing : .topLeading) {
                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        ChatBubbleShape(isMe: msg.isMe)
                            .fill(msg.isMe ? Color.outBubble : Color.inBubble)
                    )

             
                if msg.isMe {
                    HStack(spacing: 3) {
                        Text(timeFmt.string(from: msg.time))
                        if msg.delivered {
                            Image(systemName: "checkmark")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                    .offset(x: -6, y: -6)
                }
            }

     
            if !msg.isMe {
                Text(timeFmt.string(from: msg.time))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.isMe ? .trailing : .leading)
        .padding(.horizontal, 12)
    }
}

// MARK: - Input Bar

struct ChatInputBar: View {
    @Binding var text: String
    var send: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("", text: $text, prompt: Text(" "))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.inputBG)
                )

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .rotationEffect(.degrees(45))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? .gray.opacity(0.6)
                                     : .orange)
                    .padding(10)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
        
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.0001))
        )
        .padding(.horizontal, 8)
    }
}

// MARK: - Header Bar

struct ChatHeader: View {
    let title: String
    var back: () -> Void

    var body: some View {
        ZStack {
            Color.orange.ignoresSafeArea(edges: .top)

            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 6)
                Spacer()
                
                Image(systemName: "ellipsis")
                    .opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 56)
    }
}

// MARK: - Screen

struct ChatRoomView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var messages: [ChatMessage] = [
        .init(text: "Need more people here.", time: Date().addingTimeInterval(-3600), isMe: true),
        .init(text: "Do you know what time it is?", time: Date().addingTimeInterval(-120), isMe: false)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(title: "Seputa Team1") { dismiss() }

            ZStack {
                Color.canvasSand.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { ChatRow1(msg: $0) }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }

                    // 输入条
                    ChatInputBar(text: $input) {
                        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        messages.append(.init(text: trimmed, time: Date(), isMe: true))
                        input = ""
                    }
                    .background(
                        
                        Color.canvasSand
                            .overlay(
                                LinearGradient(colors: [.clear, .white.opacity(0.06)],
                                               startPoint: .center, endPoint: .bottom)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    )
                    .padding(.bottom, 8)
                    .padding(.horizontal, 8)
                }
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
    }
}

// MARK: - Preview
#Preview { NavigationStack { ChatRoomView() } }
