import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Geohash Picker using Leaflet (like Android)

struct GeohashMapView: View {
    @Binding var selectedGeohash: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        GeohashWebView(selectedGeohash: $selectedGeohash, colorScheme: colorScheme)
            .onAppear {
                // Initialize with current location if available
                if selectedGeohash.isEmpty {
                    if let currentChannel = LocationChannelManager.shared.availableChannels.first(where: { $0.level == .city || $0.level == .neighborhood }) {
                        selectedGeohash = currentChannel.geohash
                    }
                }
            }
    }
}

// MARK: - WebKit Bridge

#if os(iOS)
struct GeohashWebView: UIViewRepresentable {
    @Binding var selectedGeohash: String
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        // Enable JavaScript and disable scrolling
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        // Add JavaScript interface
        let contentController = webView.configuration.userContentController
        contentController.add(context.coordinator, name: "iOS")

        // Load the HTML content
        let htmlString = geohashPickerHTML(theme: colorScheme == .dark ? "dark" : "light")
        webView.loadHTMLString(htmlString, baseURL: nil)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Update theme if needed
        let theme = colorScheme == .dark ? "dark" : "light"
        webView.evaluateJavaScript("window.setMapTheme && window.setMapTheme('\(theme)')")

        // Focus on geohash if it changed
        if !selectedGeohash.isEmpty && context.coordinator.lastGeohash != selectedGeohash {
            webView.evaluateJavaScript("window.focusGeohash && window.focusGeohash('\(selectedGeohash)')")
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
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        // Add JavaScript interface
        let contentController = webView.configuration.userContentController
        contentController.add(context.coordinator, name: "macOS")

        // Load the HTML content
        let htmlString = geohashPickerHTML(theme: colorScheme == .dark ? "dark" : "light")
        webView.loadHTMLString(htmlString, baseURL: nil)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update theme if needed
        let theme = colorScheme == .dark ? "dark" : "light"
        webView.evaluateJavaScript("window.setMapTheme && window.setMapTheme('\(theme)')")

        // Focus on geohash if it changed
        if !selectedGeohash.isEmpty && context.coordinator.lastGeohash != selectedGeohash {
            webView.evaluateJavaScript("window.focusGeohash && window.focusGeohash('\(selectedGeohash)')")
            context.coordinator.lastGeohash = selectedGeohash
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
}
#endif

extension GeohashWebView {
    class Coordinator: NSObject, WKScriptMessageHandler {
        let parent: GeohashWebView
        var lastGeohash: String = ""

        init(_ parent: GeohashWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "iOS" || message.name == "macOS" {
                if let geohash = message.body as? String {
                    DispatchQueue.main.async {
                        self.parent.selectedGeohash = geohash
                        self.lastGeohash = geohash
                    }
                }
            }
        }
    }
}

// MARK: - Leaflet HTML (same as Android)

private func geohashPickerHTML(theme: String) -> String {
    return """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no" />
    <style>
      :root { --text: #333; }
      html, body, #map { height: 100%; margin: 0; padding: 0; background: #ffffff; }
      .leaflet-container { background: #ffffff; }
      .leaflet-div-icon { background: transparent; border: none; }
      .gh-label { background: transparent; border: none; pointer-events: none; filter: none; }
      .gh-text {
        color: #444444;
        font-weight: 700;
        font-size: 14px;
        line-height: 1;
        text-shadow: 0 0 2px #ffffff, 0 0 2px #ffffff, 0 0 2px #ffffff;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      }
      .dark .gh-text {
        color: #dddddd;
        text-shadow: 0 0 2px #000000, 0 0 2px #000000, 0 0 2px #000000;
      }
      .gh-text-selected {
        color: #00C851 !important;
      }
      .dark {
        background: #000000 !important;
      }
      .dark .leaflet-container {
        background: #000000 !important;
      }
      .leaflet-control-zoom a {
        background-color: rgba(255, 255, 255, 0.8);
        color: #333;
      }
      .dark .leaflet-control-zoom a {
        background-color: rgba(0, 0, 0, 0.8);
        color: #fff;
      }
    </style>
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  </head>
  <body class="\(theme)">
    <div id="map"></div>

    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <script>
      // Minimal geohash (bounds/encode/adjacent) - exact copy from Android
      (function () {
        const base32 = "0123456789bcdefghjkmnpqrstuvwxyz";
        function bounds(geohash) {
          let evenBit = true; let latMin = -90, latMax = 90, lonMin = -180, lonMax = 180;
          geohash = geohash.toLowerCase();
          for (let i = 0; i < geohash.length; i++) {
            const idx = base32.indexOf(geohash.charAt(i));
            if (idx == -1) throw new Error("Invalid geohash");
            for (let n = 4; n >= 0; n--) {
              const bitN = (idx >> n) & 1;
              if (evenBit) { const lonMid = (lonMin + lonMax) / 2; if (bitN == 1) lonMin = lonMid; else lonMax = lonMid; }
              else { const latMid = (latMin + latMax) / 2; if (bitN == 1) latMin = latMid; else latMax = latMid; }
              evenBit = !evenBit;
            }
          }
          return { sw: { lat: latMin, lng: lonMin }, ne: { lat: latMax, lng: lonMax } };
        }
        function encode(lat, lon, precision) {
          let idx = 0, bit = 0, evenBit = true, hash = "";
          let latMin = -90, latMax = 90, lonMin = -180, lonMax = 180;
          while (hash.length < precision) {
            if (evenBit) { const lonMid = (lonMin + lonMax) / 2; if (lon >= lonMid) { idx = idx * 2 + 1; lonMin = lonMid; } else { idx = idx * 2; lonMax = lonMid; } }
            else { const latMid = (latMin + latMax) / 2; if (lat >= latMid) { idx = idx * 2 + 1; latMin = latMid; } else { idx = idx * 2; latMax = latMid; } }
            evenBit = !evenBit; if (++bit == 5) { hash += base32.charAt(idx); bit = 0; idx = 0; }
          }
          return hash;
        }
        function adjacent(hash, dir) {
          const neighbour = { n:["p0r21436x8zb9dcf5h7kjnmqesgutwvy","bc01fg45238967deuvhjyznpkmstqrwx"], s:["14365h7k9dcfesgujnmqp0r2twvyx8zb","238967debc01fg45kmstqrwxuvhjyznp"], e:["bc01fg45238967deuvhjyznpkmstqrwx","p0r21436x8zb9dcf5h7kjnmqesgutwvy"], w:["238967debc01fg45kmstqrwxuvhjyznp","14365h7k9dcfesgujnmqp0r2twvyx8zb"] };
          const border = { n:["prxz","bcfguvyz"], s:["028b","0145hjnp"], e:["bcfguvyz","prxz"], w:["0145hjnp","028b"] };
          hash = hash.toLowerCase(); const lastCh = hash.slice(-1); let parent = hash.slice(0, -1); const type = hash.length % 2;
          if (border[dir][type].indexOf(lastCh) != -1 && parent != "") parent = adjacent(parent, dir);
          return parent + base32.charAt(neighbour[dir][type].indexOf(lastCh));
        }
        window.__geohash = { bounds, encode, adjacent };
      })();

      // Use CartoDB light/dark tiles based on theme
      const isDark = document.body.classList.contains('dark');
      const tileLayer = isDark
        ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
        : "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png";

      const map = L.map("map", { zoomControl: true, minZoom: 2, maxZoom: 21 }).setView([0, 0], 3);
      L.tileLayer(tileLayer, {
        maxZoom: 21,
        attribution: "&copy; OpenStreetMap &copy; Carto",
        opacity: 1.0
      }).addTo(map);

      let selectedGeohash = "";
      let gridLayer = L.layerGroup().addTo(map);
      let pinnedPrecision = null;
      let outlineColor = "#00C851";

      function getNeighbors(hash) {
        const neighbors = [];
        // N, S, E, W
        neighbors.push(window.__geohash.adjacent(hash, 'n'));
        neighbors.push(window.__geohash.adjacent(hash, 's'));
        neighbors.push(window.__geohash.adjacent(hash, 'e'));
        neighbors.push(window.__geohash.adjacent(hash, 'w'));
        // Diagonals
        neighbors.push(window.__geohash.adjacent(window.__geohash.adjacent(hash, 'n'), 'e'));
        neighbors.push(window.__geohash.adjacent(window.__geohash.adjacent(hash, 'n'), 'w'));
        neighbors.push(window.__geohash.adjacent(window.__geohash.adjacent(hash, 's'), 'e'));
        neighbors.push(window.__geohash.adjacent(window.__geohash.adjacent(hash, 's'), 'w'));
        return neighbors;
      }

      function pickPrecisionForViewport() {
        const c = map.getCenter();
        const minPx = 80;
        const maxPx = 240;
        let chosen = 1;
        let lastAboveMin = 1;
        for (let p = 1; p <= 12; p++) {
          const gh = window.__geohash.encode(c.lat, c.lng, p);
          const b = window.__geohash.bounds(gh);
          const pSw = map.latLngToLayerPoint([b.sw.lat, b.sw.lng]);
          const pNe = map.latLngToLayerPoint([b.ne.lat, b.ne.lng]);
          const cellPx = Math.min(Math.abs(pNe.x - pSw.x), Math.abs(pSw.y - pNe.y));
          if (cellPx >= minPx && cellPx <= maxPx) { chosen = p; break; }
          if (cellPx >= minPx) { lastAboveMin = p; }
          if (cellPx < minPx) { chosen = lastAboveMin; break; }
          if (p === 12) { chosen = 12; }
        }
        return chosen;
      }

      function notifySelection() {
        if (window.webkit && window.webkit.messageHandlers) {
          // iOS/macOS
          const handler = window.webkit.messageHandlers.iOS || window.webkit.messageHandlers.macOS;
          if (handler && selectedGeohash) {
            handler.postMessage(selectedGeohash);
          }
        }
      }

      function zoomForPrecision(p) {
        if (p <= 1) return 1; if (p === 2) return 2; if (p === 3) return 3; if (p === 4) return 4;
        if (p === 5) return 5; if (p === 6) return 7; if (p === 7) return 9; if (p === 8) return 11;
        if (p === 9) return 13; if (p === 10) return 15; if (p === 11) return 17;
        return 18;
      }

      function updateOverlay() {
        gridLayer.clearLayers();
        const c = map.getCenter();
        const usePinned = pinnedPrecision !== null;
        const p = usePinned ? pinnedPrecision : pickPrecisionForViewport();
        selectedGeohash = window.__geohash.encode(c.lat, c.lng, p);
        notifySelection();

        const centerBounds = window.__geohash.bounds(selectedGeohash);
        const centerLon = (centerBounds.sw.lng + centerBounds.ne.lng) / 2;
        const centerLat = (centerBounds.sw.lat + centerBounds.ne.lat) / 2;

        const allHashes = [selectedGeohash, ...getNeighbors(selectedGeohash)];

        const filteredHashes = allHashes.filter(gh => {
            if (!gh) return false;
            try {
                const b = window.__geohash.bounds(gh);
                const lon = (b.sw.lng + b.ne.lng) / 2;
                const lat = (b.sw.lat + b.ne.lat) / 2;
                if (Math.abs(lon - centerLon) > 180) return false; // anti-meridian wrap
                if (Math.abs(lat - centerLat) > 90) return false; // pole wrap
                return true;
            } catch (e) { return false; }
        });

        filteredHashes.forEach(gh => {
            const b = window.__geohash.bounds(gh);
            const sw = [b.sw.lat, b.sw.lng];
            const ne = [b.ne.lat, b.ne.lng];
            const isSelected = (gh === selectedGeohash);

            const rect = L.rectangle([sw, ne], {
                color: isSelected ? outlineColor : '#cccccc',
                weight: isSelected ? 3 : 1,
                fillOpacity: 0.0,
                opacity: 0.9,
                interactive: false
            });
            gridLayer.addLayer(rect);

            const center = [(b.sw.lat + b.ne.lat) / 2, (b.sw.lng + b.ne.lng) / 2];
            const labelClass = isSelected ? 'gh-text gh-text-selected' : 'gh-text';
            const label = L.marker(center, {
                icon: L.divIcon({
                    className: 'gh-label',
                    html: `<span class="${labelClass}">${gh}</span>`
                }),
                interactive: false
            });
            gridLayer.addLayer(label);
        });
      }

      map.on("movestart", () => { pinnedPrecision = null; });
      map.on("zoomstart", () => { pinnedPrecision = null; });
      map.on("moveend", updateOverlay);
      map.on("zoomend", updateOverlay);

      function setCenter(lat, lng) { map.setView([lat, lng], map.getZoom()); }
      function setPrecision(p) {
        const clamped = Math.max(1, Math.min(12, p|0));
        const targetZoom = zoomForPrecision(clamped);
        map.setZoom(targetZoom);
      }
      function focusGeohash(gh) {
        if (!gh || typeof gh !== 'string') return;
        const g = gh.toLowerCase();
        const b = window.__geohash.bounds(g);
        pinnedPrecision = g.length;
        map.fitBounds([[b.sw.lat, b.sw.lng],[b.ne.lat, b.ne.lng]], { animate: false, padding: [8,8] });
        selectedGeohash = g;
      }
      function getGeohash() { return selectedGeohash; }

      // iOS/macOS will call this with 'dark' or 'light'
      function setMapTheme(theme) {
        document.body.className = theme;
        // Recreate tile layer with new theme
        map.eachLayer(function(layer) {
          if (layer instanceof L.TileLayer) {
            map.removeLayer(layer);
          }
        });
        const isDarkTheme = theme === 'dark';
        const newTileLayer = isDarkTheme
          ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
          : "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png";
        L.tileLayer(newTileLayer, {
          maxZoom: 21,
          attribution: "&copy; OpenStreetMap &copy; Carto",
          opacity: 1.0
        }).addTo(map);
      }

      window.setCenter = setCenter;
      window.setPrecision = setPrecision;
      window.focusGeohash = focusGeohash;
      window.getGeohash = getGeohash;
      window.setMapTheme = setMapTheme;

      function cleanup() {
        try { map.off(); } catch (_) {}
        try { gridLayer.clearLayers(); } catch (_) {}
        try { map.remove(); } catch (_) {}
      }
      window.cleanup = cleanup;

      map.whenReady(updateOverlay);
    </script>
  </body>
</html>
"""
}

#Preview {
    GeohashMapView(selectedGeohash: .constant("9q8yy"))
}
