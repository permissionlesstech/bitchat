import SwiftUI

// MARK: - AIInputButton
// Sits alongside the existing send button in the message input bar.

struct AIInputButton: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Button {
            let prompt = viewModel.draftMessage
            viewModel.draftMessage = ""
            Task {
                await viewModel.askAI(prompt)
            }
        } label: {
            Group {
                if viewModel.isAIResponding {
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
            viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.isAIResponding
        )
        .accessibilityLabel("Ask AI")
    }
}

// MARK: - AIConsentAlertModifier
// Presents the consent dialog when the router needs off-device permission.
// Uses plain language because bitchat users should never have to guess
// what is happening with their data.

struct AIConsentAlertModifier: ViewModifier {
    @ObservedObject var viewModel: ChatViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                viewModel.consentPrompt?.title ?? "",
                isPresented: Binding(
                    get: { viewModel.consentPrompt != nil },
                    set: { if !$0 { viewModel.consentPrompt = nil } }
                )
            ) {
                Button("Keep on device", role: .cancel) {
                    Task { await viewModel.handleConsentResponse(granted: false) }
                }
                Button("Send") {
                    Task { await viewModel.handleConsentResponse(granted: true) }
                }
            } message: {
                Text(viewModel.consentPrompt?.message ?? "")
            }
    }
}

extension View {
    func aiConsentAlert(viewModel: ChatViewModel) -> some View {
        modifier(AIConsentAlertModifier(viewModel: viewModel))
    }
}

// MARK: - AIErrorBanner
// Shows a dismissible banner when an AI operation fails.

struct AIErrorBanner: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        if let error = viewModel.aiError {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    viewModel.aiError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
}

// MARK: - AIMessageBubble
// Renders AI responses with provider attribution and a privacy indicator.
// The lock icon means local-only; the arrow icon means data left the device.

struct AIMessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundColor(.purple)
                Text(message.senderName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.purple)

                if let level = message.privacyLevel {
                    Image(systemName: level == .local ? "lock.fill" : "arrow.up.right")
                        .font(.caption2)
                        .foregroundColor(level == .local ? .green : .orange)
                }
            }

            Text(message.text)
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
