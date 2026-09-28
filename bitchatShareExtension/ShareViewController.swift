//
// ShareViewController.swift
// bitchatShareExtension
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import UIKit
import UniformTypeIdentifiers

/// Modern share extension using UIKit + UTTypes.
/// Avoids deprecated Social framework and SLComposeServiceViewController.
final class ShareViewController: UIViewController {
    // Bundle.main.bundleIdentifier would get the extension's bundleID
    private static let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "group.chat.bitchat"

    private enum Strings {
        static let nothingToShare = String(localized: "share.status.nothing_to_share", comment: "Shown when the share extension receives no content")
        static let noShareableContent = String(localized: "share.status.no_shareable_content", comment: "Shown when provided content cannot be shared")
        static let savedForReview = String(localized: "share.status.saved_for_review", comment: "Shown after content is staged for review in the main app")
        static let failedToSave = String(localized: "share.status.failed_to_save", comment: "Shown when content cannot be staged for the main app")
    }
    
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.textColor = .label
        return l
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])
        processShare()
    }

    // MARK: - Processing
    private func processShare() {
        guard let ctx = self.extensionContext,
              let item = ctx.inputItems.first as? NSExtensionItem else {
            finishWithMessage(Strings.nothingToShare)
            return
        }

        // Preserve the whole attributed text when it contains more than a URL.
        if let payload = SharedContentPayload(
            sharedText: item.attributedContentText?.string,
            title: item.attributedTitle?.string
        ) {
            saveAndFinish(payload)
            return
        }

        // Scan attachments for URL/text
        let providers = item.attachments ?? []
        if providers.isEmpty {
            // Fallback: use attributed title as plain text
            if let title = item.attributedTitle?.string, !title.isEmpty {
                saveAndFinish(SharedContentPayload(text: title))
            } else {
                finishWithMessage(Strings.noShareableContent)
            }
            return
        }

        // Load URL or text asynchronously
        loadFirstURL(from: providers) { [weak self] url in
            guard let self = self else { return }
            if let url,
               let payload = SharedContentPayload(webURL: url, title: item.attributedTitle?.string) {
                self.saveAndFinish(payload)
            } else {
                self.loadFirstPlainText(from: providers) { text in
                    self.saveAndFinish(SharedContentPayload(
                        sharedText: text,
                        title: item.attributedTitle?.string
                    ))
                }
            }
        }
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        let identifiers = [UTType.url.identifier, "public.url", "public.file-url"]
        for provider in providers {
            guard let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                continue
            }
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                DispatchQueue.main.async { completion(Self.url(from: item)) }
            }
            return
        }
        DispatchQueue.main.async { completion(nil) }
    }

    private func loadFirstPlainText(from providers: [NSItemProvider], completion: @escaping (String?) -> Void) {
        let identifier = UTType.plainText.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(identifier) }) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
            DispatchQueue.main.async { completion(Self.string(from: item)) }
        }
    }

    private static func url(from providerItem: Any?) -> URL? {
        if let url = providerItem as? URL { return url }
        if let string = string(from: providerItem) { return URL(string: string) }
        return nil
    }

    private static func string(from providerItem: Any?) -> String? {
        if let string = providerItem as? String { return string }
        if let data = providerItem as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    // MARK: - Save + Finish
    private func saveAndFinish(_ payload: SharedContentPayload?) {
        guard let payload else {
            finishWithMessage(Strings.noShareableContent)
            return
        }
        guard let defaults = UserDefaults(suiteName: Self.groupID) else {
            finishWithMessage(Strings.failedToSave)
            return
        }
        let store = SharedContentStore(defaults: defaults)

        do {
            try store.stage(payload)
            // Staging is not sending. The main app will require a second,
            // destination-labelled confirmation before filling its composer.
            finishWithMessage(Strings.savedForReview)
        } catch {
            finishWithMessage(Strings.failedToSave)
        }
    }

    private func finishWithMessage(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusLabel.text = msg
            // Complete shortly after showing status.
            DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiShareExtensionDismissDelaySeconds) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        }
    }
}
