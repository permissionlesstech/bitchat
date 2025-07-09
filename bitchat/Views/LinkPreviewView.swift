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
    #if os(iOS)
    @State private var metadata: LPLinkMetadata?
    #endif
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
        // Always use our custom compact view for consistent appearance
        compactLinkView
            .onAppear {
                loadMetadata()
            }
    }
    
    #if os(iOS)
    @State private var previewImage: UIImage? = nil
    #endif
    
    private var compactLinkView: some View {
        Button(action: {
            #if os(iOS)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }) {
            HStack(spacing: 12) {
                // Preview image or icon
                Group {
                    #if os(iOS)
                    if let image = previewImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipped()
                            .cornerRadius(8)
                    } else {
                        // Favicon or default icon
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 60, height: 60)
                            .overlay(
                                Image(systemName: "link")
                                    .font(.system(size: 24))
                                    .foregroundColor(Color.blue)
                            )
                    }
                    #else
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Image(systemName: "link")
                                .font(.system(size: 24))
                                .foregroundColor(Color.blue)
                        )
                    #endif
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    #if os(iOS)
                    Text(metadata?.title ?? title ?? url.host ?? "Link")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    #endif
                    
                    // Host
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.6))
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark ? Color.gray.opacity(0.15) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var simpleLinkView: some View {
        Button(action: {
            #if os(iOS)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
        }) {
            HStack(spacing: 12) {
                // Link icon
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Color.blue.opacity(0.8))
                    .frame(width: 40, height: 40)
                
                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(title ?? url.host ?? "Link")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    // URL
                    Text(url.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                // Arrow indicator
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(textColor.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(colorScheme == .dark ? Color.gray.opacity(0.15) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func loadMetadata() {
        #if os(iOS)
        guard metadata == nil else { return }
        
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { fetchedMetadata, error in
            DispatchQueue.main.async {
                if let fetchedMetadata = fetchedMetadata {
                    // Use the fetched metadata, or create new with our title
                    if let title = self.title, !title.isEmpty {
                        fetchedMetadata.title = title
                    }
                    self.metadata = fetchedMetadata
                    
                    // Try to extract image
                    if let imageProvider = fetchedMetadata.imageProvider {
                        imageProvider.loadObject(ofClass: UIImage.self) { image, error in
                            DispatchQueue.main.async {
                                if let image = image as? UIImage {
                                    self.previewImage = image
                                }
                            }
                        }
                    }
                }
            }
        }
        #endif
    }
}

#if os(iOS)
// UIViewRepresentable wrapper for LPLinkView
struct LinkPreview: UIViewRepresentable {
    let metadata: LPLinkMetadata
    
    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = .clear
        
        let linkView = LPLinkView(metadata: metadata)
        linkView.isUserInteractionEnabled = false // We handle taps at the SwiftUI level
        linkView.translatesAutoresizingMaskIntoConstraints = false
        
        containerView.addSubview(linkView)
        NSLayoutConstraint.activate([
            linkView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            linkView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            linkView.topAnchor.constraint(equalTo: containerView.topAnchor),
            linkView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Update if needed
    }
}
#endif

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
                    let isPartOfMarkdown = urls.contains { $0.1.overlaps(range) }
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
