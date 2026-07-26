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
        static let sharedLinkTitleFallback = String(localized: "share.fallback.shared_link_title", comment: "Fallback title when saving a shared link")
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

        // Try content from attributed text first (Safari often passes URL here)
        if let url = detectURL(in: item.attributedContentText?.string ?? "") {
            saveAndFinish(url: url, title: item.attributedTitle?.string)
            return
        }

        // Scan attachments for URL/text
        let providers = item.attachments ?? []
        if providers.isEmpty {
            // Fallback: use attributed title as plain text
            if let title = item.attributedTitle?.string, !title.isEmpty {
                saveAndFinish(text: title)
            } else {
                finishWithMessage(Strings.noShareableContent)
            }
            return
        }

        // Load URL or text asynchronously
        loadFirstURL(from: providers) { [weak self] url in
            guard let self = self else { return }
            if let url = url {
                self.saveAndFinish(url: url, title: item.attributedTitle?.string)
            } else {
                self.loadFirstPlainText(from: providers) { text in
                    if let t = text, !t.isEmpty {
                        // Treat as URL if parseable http(s), else plain text
                        if let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                            self.saveAndFinish(url: u, title: item.attributedTitle?.string)
                        } else {
                            self.saveAndFinish(text: t)
                        }
                    } else {
                        self.finishWithMessage(Strings.noShareableContent)
                    }
                }
            }
        }
    }

    private func detectURL(in text: String) -> URL? {
        guard !text.isEmpty else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let match = detector?.matches(in: text, options: [], range: range).first
        return match?.url
    }

    private func loadFirstURL(from providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
        let identifiers = [UTType.url.identifier, "public.url", "public.file-url"]
        for provider in providers {
            guard let identifier = identifiers.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
                continue
            }
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let result: URL?
                if let url = item as? URL {
                    result = url
                } else if let string = item as? String {
                    result = URL(string: string)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    result = URL(string: string)
                } else {
                    result = nil
                }
                DispatchQueue.main.async { completion(result) }
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
            let result: String?
            if let string = item as? String {
                result = string
            } else if let data = item as? Data {
                result = String(data: data, encoding: .utf8)
            } else {
                result = nil
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Save + Finish
    private func saveAndFinish(url: URL, title: String?) {
        let payload = SharedContentPayload(
            kind: .url,
            content: url.absoluteString,
            title: title ?? url.host ?? Strings.sharedLinkTitleFallback
        )
        stageAndFinish(payload)
    }

    private func saveAndFinish(text: String) {
        stageAndFinish(.text(text))
    }

    private func stageAndFinish(_ payload: SharedContentPayload) {
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
