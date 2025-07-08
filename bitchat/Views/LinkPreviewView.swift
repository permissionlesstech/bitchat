//
// LinkPreviewView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import LinkPresentation
#endif

struct LinkPreviewView: View {
    let url: URL
    let title: String?
    @Environment(\.colorScheme) var colorScheme
    @State private var isLoadingMetadata = false
    @State private var metadata: LinkMetadata?
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var borderColor: Color {
        textColor.opacity(0.3)
    }
    
    var body: some View {
        Button(action: {
            #if os(iOS)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Title
                Text(metadata?.title ?? title ?? url.host ?? "Link")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                // URL
                Text(url.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textColor.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                // Description if available
                if let description = metadata?.description {
                    Text(description)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            loadMetadata()
        }
    }
    
    private func loadMetadata() {
        #if os(iOS)
        guard metadata == nil && !isLoadingMetadata else { return }
        
        isLoadingMetadata = true
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { metadata, error in
            DispatchQueue.main.async {
                if let metadata = metadata {
                    self.metadata = LinkMetadata(
                        title: metadata.title,
                        description: metadata.value(forKey: "_summary") as? String,
                        imageURL: metadata.imageProvider?.value(forKey: "_URL") as? URL
                    )
                }
                self.isLoadingMetadata = false
            }
        }
        #endif
    }
}

struct LinkMetadata {
    let title: String?
    let description: String?
    let imageURL: URL?
}

// Helper to extract URLs from text
extension String {
    func extractURLs() -> [(url: URL, range: Range<String.Index>)] {
        var urls: [(URL, Range<String.Index>)] = []
        
        // Check for markdown-style links [title](url)
        let markdownPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: markdownPattern) {
            let matches = regex.matches(in: self, range: NSRange(location: 0, length: self.utf16.count))
            for match in matches {
                if let urlRange = Range(match.range(at: 2), in: self),
                   let url = URL(string: String(self[urlRange])),
                   let fullRange = Range(match.range, in: self) {
                    urls.append((url, fullRange))
                }
            }
        }
        
        // Also check for plain URLs
        let types: NSTextCheckingResult.CheckingType = .link
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let matches = detector.matches(in: self, range: NSRange(location: 0, length: self.utf16.count))
            for match in matches {
                if let range = Range(match.range, in: self),
                   let url = match.url {
                    // Don't add if this URL is already part of a markdown link
                    let isPartOfMarkdown = urls.contains { $0.range.overlaps(range) }
                    if !isPartOfMarkdown {
                        urls.append((url, range))
                    }
                }
            }
        }
        
        return urls
    }
    
    func extractMarkdownLink() -> (title: String, url: URL)? {
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: self, range: NSRange(location: 0, length: self.utf16.count)) {
            if let titleRange = Range(match.range(at: 1), in: self),
               let urlRange = Range(match.range(at: 2), in: self),
               let url = URL(string: String(self[urlRange])) {
                return (String(self[titleRange]), url)
            }
        }
        return nil
    }
}

#Preview {
    VStack {
        LinkPreviewView(url: URL(string: "https://example.com")!, title: "Example Website")
            .padding()
    }
}