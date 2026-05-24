import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Geohash Picker using Leaflet

struct GeohashMapView: View {
    @Binding var selectedGeohash: String
    let initialGeohash: String
    let showFloatingControls: Bool
    @Binding var precision: Int?
    @Environment(\.colorScheme) var colorScheme
    @State private var webViewCoordinator: GeohashWebView.Coordinator?
    @State private var currentPrecision: Int = 6 // Default to neighborhood level
    @State private var isPinned: Bool = false
    
    init(selectedGeohash: Binding<String>, initialGeohash: String = "", showFloatingControls: Bool = true, precision: Binding<Int?> = .constant(nil)) {
        self._selectedGeohash = selectedGeohash
        self.initialGeohash = initialGeohash
        self.showFloatingControls = showFloatingControls
        self._precision = precision
    }
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    var body: some View {
        ZStack {
            // Full-screen map
            GeohashWebView(
                selectedGeohash: $selectedGeohash,
                initialGeohash: initialGeohash,
                colorScheme: colorScheme,
                currentPrecision: $currentPrecision,
                isPinned: $isPinned,
                onCoordinatorCreated: { coordinator in
                    DispatchQueue.main.async {
                        self.webViewCoordinator = coordinator
                    }
                }
            )
            .ignoresSafeArea()
            
            // Floating precision controls
            if showFloatingControls {
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            // Plus button
                            Button(action: {
                                if currentPrecision < 12 {
                                    currentPrecision += 1
                                    isPinned = true
                                    webViewCoordinator?.setPrecision(currentPrecision)
                                }
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(colorScheme == .dark ? .white : .black)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        Circle()
                                            .fill(colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                            )
                                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                                    )
                            }
                            .disabled(currentPrecision >= 12)
                            .opacity(currentPrecision >= 12 ? 0.5 : 1.0)
                            
                            // Minus button
                            Button(action: {
                                if currentPrecision > 1 {
                                    currentPrecision -= 1
                                    isPinned = true
                                    webViewCoordinator?.setPrecision(currentPrecision)
                                }
                            }) {
                                Image(systemName: "minus")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(colorScheme == .dark ? .white : .black)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        Circle()
                                            .fill(colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                            )
                                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                                    )
                            }
                            .disabled(currentPrecision <= 1)
                            .opacity(currentPrecision <= 1 ? 0.5 : 1.0)
                        }
                        .padding(.trailing, 16)
                        .padding(.top, 80)
                    }
                    Spacer()
                }
            }
            
            // Bottom geohash info overlay
            if showFloatingControls {
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if !selectedGeohash.isEmpty {
                                Text("#\(selectedGeohash)")
                                    .font(.bitchatSystem(size: 16, weight: .semibold, design: .monospaced))
                                    .foregroundColor(textColor)
                            } else {
                                Text(String(localized: "geohash_picker.instruction", comment: "Instruction text for geohash map picker"))
                                    .font(.bitchatSystem(size: 14, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("precision: \(currentPrecision) • \(levelName(for: currentPrecision))")
                                .font(.bitchatSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        Rectangle()
                            .fill(colorScheme == .dark ? Color.black.opacity(0.9) : Color.white.opacity(0.9))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                }
            }
        }
        .onAppear {
            // Set initial precision based on selected geohash length
            if !selectedGeohash.isEmpty {
                currentPrecision = selectedGeohash.count
            } else if !initialGeohash.isEmpty {
                currentPrecision = initialGeohash.count
            }
        }
        .onChange(of: selectedGeohash) { newValue in
            if !newValue.isEmpty && newValue.count != currentPrecision && !isPinned {
                currentPrecision = newValue.count
            }
        }
        .onChange(of: precision) { newValue in
            if let newPrecision = newValue, newPrecision != currentPrecision {
                currentPrecision = newPrecision
                isPinned = true
                webViewCoordinator?.setPrecision(currentPrecision)
            }
        }
        .onChange(of: currentPrecision) { newValue in
            precision = newValue
        }
    }
    
    private func levelName(for precision: Int) -> String {
        let level = levelForPrecision(precision)
        return level.displayName.lowercased()
    }
    
    private func levelForPrecision(_ precision: Int) -> GeohashChannelLevel {
        switch precision {
        case 8: return .building
        case 7: return .block
        case 6: return .neighborhood
        case 5: return .city
        case 4: return .province
        case 0...3: return .region
        default: return .neighborhood // Default fallback
        }
    }
    
}



// MARK: - WebKit Bridge

#if os(iOS)
struct GeohashWebView: UIViewRepresentable {
    @Binding var selectedGeohash: String
    let initialGeohash: String
    let colorScheme: ColorScheme
    @Binding var currentPrecision: Int
    @Binding var isPinned: Bool
    let onCoordinatorCreated: (Coordinator) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Configure to allow all touch events to pass through to web content
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)

        // Store webView reference in coordinator
        context.coordinator.webView = webView

        // Notify parent of coordinator creation
        onCoordinatorCreated(context.coordinator)

        // Enable JavaScript and configure touch gestures
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear

        // Enable touch gestures and zoom
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        webView.scrollView.bouncesZoom = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false

        // Allow multiple touch gestures and disable WebView's native zoom to let Leaflet handle it
        webView.allowsBackForwardNavigationGestures = false
        webView.isMultipleTouchEnabled = true
        webView.isUserInteractionEnabled = true

        // Disable WebView's native zoom so Leaflet can handle double-tap zoom
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.zoomScale = 1.0

        // Add JavaScript interface
        let contentController = webView.configuration.userContentController
        contentController.add(context.coordinator, name: "iOS")

        // Set navigation delegate to handle page load completion
        webView.navigationDelegate = context.coordinator

        // Load the HTML content from Resources folder
        if let path = Bundle.main.path(forResource: "geohash-map", ofType: "html"),
           let htmlString = try? String(contentsOfFile: path) {
            let theme = colorScheme == .dark ? "dark" : "light"
            let processedHTML = htmlString.replacingOccurrences(of: "{{THEME}}", with: theme)
            webView.loadHTMLString(processedHTML, baseURL: Bundle.main.bundleURL)
        }

        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Update theme if needed
        let theme = colorScheme == .dark ? "dark" : "light"
        webView.evaluateJavaScript("window.setMapTheme && window.setMapTheme('\(theme)')")
        
        // Focus on geohash if it changed
        if !selectedGeohash.isEmpty && context.coordinator.lastGeohash != selectedGeohash {
            // Use setTimeout to ensure map is ready
            webView.evaluateJavaScript("""
                setTimeout(function() {
                    if (window.focusGeohash) {
                        window.focusGeohash('\(selectedGeohash)');
                    }
                }, 100);
            """)
            context.coordinator.lastGeohash = selectedGeohash
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
#elseif os(macOS)
struct GeohashWebView: NSViewRepresentable {
    @Binding var selectedGeohash: String
    let initialGeohash: String
    let colorScheme: ColorScheme
    @Binding var currentPrecision: Int
    @Binding var isPinned: Bool
    let onCoordinatorCreated: (Coordinator) -> Void
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        // Store webView reference in coordinator
        context.coordinator.webView = webView

        // Notify parent of coordinator creation
        onCoordinatorCreated(context.coordinator)

        // Add JavaScript interface
        let contentController = webView.configuration.userContentController
        contentController.add(context.coordinator, name: "macOS")

        webView.navigationDelegate = context.coordinator

        // Load the HTML content from Resources folder
        if let path = Bundle.main.path(forResource: "geohash-map", ofType: "html"),
           let htmlString = try? String(contentsOfFile: path) {
            let theme = colorScheme == .dark ? "dark" : "light"
            let processedHTML = htmlString.replacingOccurrences(of: "{{THEME}}", with: theme)
            webView.loadHTMLString(processedHTML, baseURL: Bundle.main.bundleURL)
        }

        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let theme = colorScheme == .dark ? "dark" : "light"
        webView.evaluateJavaScript("window.setMapTheme && window.setMapTheme('\(theme)')")
        
        // Focus on geohash if it changed
        if !selectedGeohash.isEmpty && context.coordinator.lastGeohash != selectedGeohash {
            // Use setTimeout to ensure map is ready
            webView.evaluateJavaScript("""
                setTimeout(function() {
                    if (window.focusGeohash) {
                        window.focusGeohash('\(selectedGeohash)');
                    }
                }, 100);
            """)
            context.coordinator.lastGeohash = selectedGeohash
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
#endif

extension GeohashWebView {
    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: GeohashWebView
        var webView: WKWebView?
        var hasLoadedOnce = false
        var lastGeohash: String = ""
        var isInitializing = true
        
        // Map state persistence
        private let mapStateKey = "GeohashMapView.lastMapState"
        
        init(_ parent: GeohashWebView) {
            self.parent = parent
            super.init()
        }
        
        private func saveMapState(lat: Double, lng: Double, zoom: Double, precision: Int?) {
            var state: [String: Any] = [
                "lat": lat,
                "lng": lng,
                "zoom": zoom
            ]
            if let precision = precision {
                state["precision"] = precision
            }
            UserDefaults.standard.set(state, forKey: mapStateKey)
        }
        
        private func loadMapState() -> (lat: Double, lng: Double, zoom: Double, precision: Int?)? {
            guard let state = UserDefaults.standard.dictionary(forKey: mapStateKey),
                  let lat = state["lat"] as? Double,
                  let lng = state["lng"] as? Double,
                  let zoom = state["zoom"] as? Double else {
                return nil
            }
            let precision = state["precision"] as? Int
            return (lat, lng, zoom, precision)
        }
        
        func focusOnCurrentGeohash() {
            guard let webView = webView, !parent.selectedGeohash.isEmpty else {
                return
            }
            webView.evaluateJavaScript("""
                setTimeout(function() {
                    if (window.focusGeohash) {
                        window.focusGeohash('\(parent.selectedGeohash)');
                    }
                }, 100);
            """)
        }
        
        func setPrecision(_ precision: Int) {
            guard let webView = webView else { return }
            webView.evaluateJavaScript("""
                setTimeout(function() {
                    if (window.setPrecision) {
                        window.setPrecision(\(precision));
                    }
                }, 100);
            """)
        }
        
        func restoreMapState(lat: Double, lng: Double, zoom: Double, precision: Int?) {
            guard let webView = webView else { return }
            let precisionValue = precision != nil ? "\(precision!)" : "null"
            webView.evaluateJavaScript("""
                setTimeout(function() {
                    if (window.restoreMapState) {
                        window.restoreMapState(\(lat), \(lng), \(zoom), \(precisionValue));
                    }
                }, 100);
            """)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            var geohashToFocus: String? = nil
            
            if !parent.initialGeohash.isEmpty {
                geohashToFocus = parent.initialGeohash
                // Update selectedGeohash to match the initial geohash
                DispatchQueue.main.async {
                    self.parent.selectedGeohash = self.parent.initialGeohash
                }
            }
            else if !parent.selectedGeohash.isEmpty {
                geohashToFocus = parent.selectedGeohash
            }
            else if !hasLoadedOnce {
                if let state = loadMapState() {
                    restoreMapState(lat: state.lat, lng: state.lng, zoom: state.zoom, precision: state.precision)
                    hasLoadedOnce = true
                    
                    let theme = parent.colorScheme == .dark ? "dark" : "light"
                    webView.evaluateJavaScript("window.setMapTheme && window.setMapTheme('\(theme)')")
                    
                    isInitializing = false
                    return
                }
                else if let currentChannel = LocationChannelManager.shared.availableChannels.first(where: { $0.level == .city || $0.level == .neighborhood }) {
                    geohashToFocus = currentChannel.geohash
                }
            }
            
            hasLoadedOnce = true
            
            if let geohash = geohashToFocus {
                lastGeohash = geohash
                webView.evaluateJavaScript("window.focusGeohash && window.focusGeohash('\(geohash)')")
            }
            
            let theme = parent.colorScheme == .dark ? "dark" : "light"
            webView.evaluateJavaScript("window.setMapTheme && window.setMapTheme('\(theme)')")
            
            isInitializing = false
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "iOS" || message.name == "macOS" {
                if let geohash = message.body as? String {
                    DispatchQueue.main.async {
                        self.parent.selectedGeohash = geohash
                        self.lastGeohash = geohash
                    }
                } else if let dict = message.body as? [String: Any],
                          let type = dict["type"] as? String {
                    if type == "precision", let precision = dict["value"] as? Int {
                        DispatchQueue.main.async {
                            if !self.parent.isPinned {
                                self.parent.currentPrecision = precision
                            }
                        }
                    } else if type == "geohash", let geohash = dict["value"] as? String {
                        // Only update selectedGeohash if this isn't just an automatic center change
                        // during focusing on a specific geohash or during initialization
                        if geohash != self.lastGeohash && !self.isInitializing {
                            DispatchQueue.main.async {
                                self.parent.selectedGeohash = geohash
                                self.lastGeohash = geohash
                            }
                        }
                    } else if type == "saveMapState",
                              let stateData = dict["value"] as? [String: Any],
                              let lat = stateData["lat"] as? Double,
                              let lng = stateData["lng"] as? Double,
                              let zoom = stateData["zoom"] as? Double {
                        let precision = stateData["precision"] as? Int
                        DispatchQueue.main.async {
                            self.saveMapState(lat: lat, lng: lng, zoom: zoom, precision: precision)
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    GeohashMapView(selectedGeohash: .constant(""), initialGeohash: "")
}
