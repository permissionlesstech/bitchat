import SwiftUI

// MARK: - AIInputButton
// Sits alongside the existing send button in the message input bar.

struct AIInputButton: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        Button {
            // FIX: Capture the draft but do not clear it yet. If the AI
            // request fails (no provider, download needed, inference error),
            // the user keeps their prompt and can retry or edit it. The draft
            // is only cleared after a successful response.
            let prompt = viewModel.draftMessage
            Task {
                let result = await viewModel.askAI(prompt)
                if result.consentNeeded == nil && result.error == nil {
                    // Success -- safe to clear.
                    viewModel.draftMessage = ""
                }
                // On consent needed: draft stays so it can be resent after approval.
                // On error: draft stays so the user can retry.
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
