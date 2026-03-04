//
// AIInputButton.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

// MARK: - AIInputButton
// Sits alongside the existing send button in the message input bar.
// Takes a binding to the message text and a callback for successful responses.
// No dependency on ChatViewModel — only AIState.

struct AIInputButton: View {
    @ObservedObject var aiState: AIState
    @Binding var messageText: String
    var onMessage: (BitchatMessage) -> Void

    var body: some View {
        Button {
            let prompt = messageText
            Task {
                if let message = await aiState.askAI(prompt) {
                    messageText = ""
                    onMessage(message)
                }
            }
        } label: {
            Group {
                if aiState.isAIResponding {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "brain")
                        .font(.system(size: 20))
                }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(
            messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || aiState.isAIResponding
        )
        .accessibilityLabel("Ask AI")
    }
}

// MARK: - AIConsentAlertModifier

struct AIConsentAlertModifier: ViewModifier {
    @ObservedObject var aiState: AIState
    var onMessage: (BitchatMessage) -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                aiState.consentPrompt?.title ?? "",
                isPresented: Binding(
                    get: { aiState.consentPrompt != nil },
                    set: { if !$0 { aiState.consentPrompt = nil } }
                )
            ) {
                Button("Keep on device", role: .cancel) {
                    Task { _ = await aiState.handleConsentResponse(granted: false) }
                }
                Button("Send") {
                    Task {
                        if let message = await aiState.handleConsentResponse(granted: true) {
                            onMessage(message)
                        }
                    }
                }
            } message: {
                Text(aiState.consentPrompt?.message ?? "")
            }
    }
}

extension View {
    func aiConsentAlert(aiState: AIState, onMessage: @escaping (BitchatMessage) -> Void) -> some View {
        modifier(AIConsentAlertModifier(aiState: aiState, onMessage: onMessage))
    }
}

// MARK: - AIErrorBanner

struct AIErrorBanner: View {
    @ObservedObject var aiState: AIState

    var body: some View {
        if let error = aiState.aiError {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    aiState.aiError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
}

// MARK: - AIMessageBubble

struct AIMessageBubble: View {
    let message: BitchatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundColor(.purple)
                Text(message.sender)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.purple)
            }

            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}
