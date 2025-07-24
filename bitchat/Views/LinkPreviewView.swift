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
import UIKit
#endif

// MARK: - Link Metadata Cache

/// Cache for link metadata to prevent repeated network requests
private class LinkMetadataCache {
    static let shared = LinkMetadataCache()
    
    #if os(iOS)
    private let cache = NSCache<NSURL, CachedMetadata>()
    private let imageCache = NSCache<NSURL, UIImage>()
    #endif
    private let queue = DispatchQueue(label: "chat.bitchat.linkmetadata.cache", attributes: .concurrent)
    
    private init() {
        #if os(iOS)
        cache.countLimit = 100 // Keep metadata for up to 100 URLs
        imageCache.countLimit = 50 // Keep images for up to 50 URLs
        imageCache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit for images
        #endif
    }
    
    #if os(iOS)
    class CachedMetadata {
        let metadata: LPLinkMetadata?
        let title: String?
        let host: String?
        let error: Error?
        let timestamp: Date
        
        init(metadata: LPLinkMetadata? = nil, title: String? = nil, host: String? = nil, error: Error? = nil) {
            self.metadata = metadata
            self.title = title
            self.host = host
            self.error = error
            self.timestamp = Date()
        }
    }
    
    func getCachedMetadata(for url: URL) -> (metadata: LPLinkMetadata?, title: String?, host: String?, image: UIImage?)? {
        return queue.sync {
            guard let cached = cache.object(forKey: url as NSURL) else { return nil }
            
            // Check if cache is older than 24 hours
            if Date().timeIntervalSince(cached.timestamp) > 86400 {
                cache.removeObject(forKey: url as NSURL)
                imageCache.removeObject(forKey: url as NSURL)
                return nil
            }
            
            let image = imageCache.object(forKey: url as NSURL)
            return (cached.metadata, cached.title, cached.host, image)
        }
    }
    
    func cacheMetadata(_ metadata: LPLinkMetadata?, title: String?, host: String?, image: UIImage?, for url: URL) {
        queue.async(flags: .barrier) {
            let cached = CachedMetadata(metadata: metadata, title: title, host: host)
            self.cache.setObject(cached, forKey: url as NSURL)
            
            if let image = image {
                let cost = Int(image.size.width * image.size.height * 4) // Approximate memory usage
                self.imageCache.setObject(image, forKey: url as NSURL, cost: cost)
            }
        }
    }
    
    func cacheError(_ error: Error, for url: URL) {
        queue.async(flags: .barrier) {
            let cached = CachedMetadata(error: error)
            self.cache.setObject(cached, forKey: url as NSURL)
        }
    }
    #endif
    
    func clearCache() {
        queue.async(flags: .barrier) {
            #if os(iOS)
            self.cache.removeAllObjects()
            self.imageCache.removeAllObjects()
            #endif
        }
    }
}

// MARK: - Link Preview View

struct LinkPreviewView: View {
    let url: URL
    let title: String?
    @Environment(\.colorScheme) var colorScheme
    #if os(iOS)
    @State private var metadata: LPLinkMetadata?
    @State private var cachedTitle: String?
    @State private var cachedHost: String?
    @State private var isLoading = false
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
                loadFromCacheOrFetch()
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
                    Text(cachedTitle ?? metadata?.title ?? title ?? url.host ?? "Link")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    #else
                    Text(title ?? url.host ?? "Link")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    #endif
                    
                    // Host
                    #if os(iOS)
                    Text(cachedHost ?? url.host ?? url.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.6))
                        .lineLimit(1)
                    #else
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.6))
                        .lineLimit(1)
                    #endif
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
    
    private func loadFromCacheOrFetch() {
        #if os(iOS)
        // Check if we already have data in state
        guard metadata == nil && !isLoading else { 
            return 
        }
        
        // Check cache first
        if let cached = LinkMetadataCache.shared.getCachedMetadata(for: url) {
            // print("🔗 LinkPreviewView: Using CACHED metadata for: \(url.absoluteString)")
            self.metadata = cached.metadata
            self.cachedTitle = cached.title ?? cached.metadata?.title
            self.cachedHost = cached.host ?? url.host
            self.previewImage = cached.image
            return
        }
        
        // Not in cache, fetch it
        // print("🔗 LinkPreviewView: FETCHING metadata for: \(url.absoluteString)")
        isLoading = true
        
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { fetchedMetadata, error in
            DispatchQueue.main.async {
                self.isLoading = false
                
                if let error = error {
                    // Check if it's an ATS error for subresources (non-critical)
                    let errorString = error.localizedDescription.lowercased()
                    let isATSError = errorString.contains("app transport security") || 
                                    errorString.contains("secure connection")
                    
                    if !isATSError {
                        // Only log non-ATS errors
                        // print("🔗 LinkPreviewView: Error fetching metadata: \(error)")
                    }
                    
                    // Still try to show basic preview with URL info
                    self.cachedTitle = self.title ?? self.url.host
                    self.cachedHost = self.url.host
                    
                    // Cache even failed attempts to avoid repeated fetches
                    LinkMetadataCache.shared.cacheMetadata(
                        nil,
                        title: self.cachedTitle,
                        host: self.cachedHost,
                        image: nil,
                        for: self.url
                    )
                    return
                }
                
                if let fetchedMetadata = fetchedMetadata {
                    // Use the fetched metadata, or create new with our title
                    if let title = self.title, !title.isEmpty {
                        fetchedMetadata.title = title
                    }
                    self.metadata = fetchedMetadata
                    self.cachedTitle = fetchedMetadata.title ?? self.title
                    self.cachedHost = self.url.host
                    
                    // Try to extract image
                    if let imageProvider = fetchedMetadata.imageProvider {
                        imageProvider.loadObject(ofClass: UIImage.self) { image, error in
                            DispatchQueue.main.async {
                                if let image = image as? UIImage {
                                    self.previewImage = image
                                    // Cache everything including the image
                                    LinkMetadataCache.shared.cacheMetadata(
                                        fetchedMetadata,
                                        title: self.cachedTitle,
                                        host: self.cachedHost,
                                        image: image,
                                        for: self.url
                                    )
                                } else {
                                    // Cache without image
                                    LinkMetadataCache.shared.cacheMetadata(
                                        fetchedMetadata,
                                        title: self.cachedTitle,
                                        host: self.cachedHost,
                                        image: nil,
                                        for: self.url
                                    )
                                }
                            }
                        }
                    } else {
                        // No image, cache what we have
                        LinkMetadataCache.shared.cacheMetadata(
                            fetchedMetadata,
                            title: self.cachedTitle,
                            host: self.cachedHost,
                            image: nil,
                            for: self.url
                        )
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
        
        // Check for plain URLs
        let types: NSTextCheckingResult.CheckingType = .link
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let matches = detector.matches(in: self, range: NSRange(location: 0, length: self.utf16.count))
            for match in matches {
                if let range = Range(match.range, in: self),
                   let url = match.url {
                    urls.append((url, range))
                }
            }
        }
        
        return urls
    }
}

#Preview {
    VStack {
        LinkPreviewView(url: URL(string: "https://example.com")!, title: "Example Website")
            .padding()
    }
}
