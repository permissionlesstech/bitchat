Place Tor.xcframework here

Instructions
- Obtain a prebuilt Tor Apple xcframework (iCepa/Onion Browser lineage) or build your own minimal client-only Tor.
- Rename it (if needed) to `Tor.xcframework` and drop it in this `Frameworks/` directory.
- Regenerate the Xcode project if you use XcodeGen (`project.yml` already references `Frameworks/Tor.xcframework`).
- Build the app; `TorManager` will automatically bootstrap Tor and route all networking through it.

Notes
- For iOS, the framework will be embedded and code-signed automatically.
- For macOS, it will be linked and embedded as well (you may prefer a system tor for smaller bundles).

