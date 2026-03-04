import SwiftUI

// MARK: - AISettingsView
// Shows model info, download/delete actions, and privacy notices.
// Privacy strings come from Localizable.strings for localization.

struct AISettingsView: View {
    @ObservedObject var router: AIProviderRouter
    @ObservedObject var localProvider: MLXAIProvider
    @State private var showDeleteConfirmation = false

    var body: some View {
        Section {
            if let model = localProvider.selectedModel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.displayName)
                            .font(.headline)
                        Spacer()
                        Text(model.quantization)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                    Text("Size: \(model.formattedDiskSize)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if localProvider.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: localProvider.downloadProgress)
                        Text("Downloading... \(Int(localProvider.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if localProvider.isModelReady {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Ready")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } else {
                    Button {
                        Task {
                            try? await localProvider.downloadModel()
                            router.resolveCurrentProvider()
                        }
                    } label: {
                        Label("Download Model", systemImage: "arrow.down.circle")
                    }
                }

                if let error = localProvider.downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else {
                Text("No compatible AI model is available for this device.")
                    .foregroundColor(.secondary)
            }

            // Privacy notice for local processing
            Text(NSLocalizedString("ai.privacy.local", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)

        } header: {
            Text("Local AI")
        }

        // Bridge provider section
        Section {
            ForEach(router.bridgedProviders, id: \.id) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.displayName)
                            .font(.headline)
                        Spacer()
                        if provider.isAvailable {
                            Text("Available")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("Coming Soon")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(NSLocalizedString("ai.privacy.bridged", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if provider.isAvailable {
                        Toggle(
                            "Allow off-device processing",
                            isOn: Binding(
                                get: { router.hasUserConsent(for: .bridged) },
                                set: { router.setUserConsent(for: .bridged, granted: $0) }
                            )
                        )
                    }
                }
            }
        } header: {
            Text("AI Bridge")
        }
        .confirmationDialog(
            "Delete AI Model?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await localProvider.deleteModel()
                    router.resolveCurrentProvider()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let model = localProvider.selectedModel {
                Text("This will free \(model.formattedDiskSize) of storage. You can re-download later.")
            }
        }
    }
}
