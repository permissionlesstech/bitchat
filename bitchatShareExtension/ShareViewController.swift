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
    private static let groupID = "group.chat.bitchat"
    
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
            finishWithMessage("Nothing to share")
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
                finishWithMessage("No shareable content")
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
                        if let u = URL(string: t), ["http","https"].contains(u.scheme?.lowercased() ?? "") {
                            self.saveAndFinish(url: u, title: item.attributedTitle?.string)
                        } else {
                            self.saveAndFinish(text: t)
                        }
                    } else {
                        self.finishWithMessage("No shareable content")
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
        let grp = DispatchGroup()
        var found: URL?

        for p in providers where found == nil {
            for id in identifiers where p.hasItemConformingToTypeIdentifier(id) {
                grp.enter()
                p.loadItem(forTypeIdentifier: id, options: nil) { item, _ in
                    defer { grp.leave() }
                    if let u = item as? URL { found = u; return }
                    if let s = item as? String, let u = URL(string: s) { found = u; return }
                    if let d = item as? Data, let s = String(data: d, encoding: .utf8), let u = URL(string: s) { found = u; return }
                }
                break
            }
        }
        grp.notify(queue: .main) { completion(found) }
    }

    private func loadFirstPlainText(from providers: [NSItemProvider], completion: @escaping (String?) -> Void) {
        let id = UTType.plainText.identifier
        let grp = DispatchGroup()
        var text: String?
        for p in providers where p.hasItemConformingToTypeIdentifier(id) {
            grp.enter()
            p.loadItem(forTypeIdentifier: id, options: nil) { item, _ in
                defer { grp.leave() }
                if let s = item as? String { text = s }
                else if let d = item as? Data, let s = String(data: d, encoding: .utf8) { text = s }
            }
            break
        }
        grp.notify(queue: .main) { completion(text) }
    }

    // MARK: - Save + Finish
    private func saveAndFinish(url: URL, title: String?) {
        let payload: [String: String] = [
            "url": url.absoluteString,
            "title": title ?? url.host ?? "Shared Link"
        ]
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: json, encoding: .utf8) {
            saveToSharedDefaults(content: s, type: "url")
            finishWithMessage("✓ Shared link to bitchat")
        } else {
            finishWithMessage("Failed to encode link")
        }
    }

    private func saveAndFinish(text: String) {
        saveToSharedDefaults(content: text, type: "text")
        finishWithMessage("✓ Shared text to bitchat")
    }

    private func saveToSharedDefaults(content: String, type: String) {
        guard let userDefaults = UserDefaults(suiteName: Self.groupID) else { return }
        userDefaults.set(content, forKey: "sharedContent")
        userDefaults.set(type, forKey: "sharedContentType")
        userDefaults.set(Date(), forKey: "sharedContentDate")
        // No need to force synchronize; the system persists changes
    }

    private func finishWithMessage(_ msg: String) {
        statusLabel.text = msg
        // Complete shortly after showing status
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiShareExtensionDismissDelaySeconds) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
