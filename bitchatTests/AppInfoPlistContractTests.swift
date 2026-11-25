import Foundation
import Testing

/// Pins the platform keys in the hand-written app Info.plist (shared by the
/// iOS and macOS targets) that decide how bitchat is laid out on iPhone Duo,
/// so a merge or an Xcode migration can't quietly bring the old values back.
struct AppInfoPlistContractTests {
    private static let infoPlistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("bitchat/Info.plist")

    private static func loadInfoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func doesNotRequireFullScreen() throws {
        let plist = try Self.loadInfoPlist()
        // With it, iPhone Duo's inner display letterboxes bitchat into a narrow portrait window.
        #expect(plist["UIRequiresFullScreen"] == nil)
    }

    @Test func staysSingleScene() throws {
        let plist = try Self.loadInfoPlist()
        let manifest = try #require(plist["UIApplicationSceneManifest"] as? [String: Any])
        // DM selection, drafts, the privacy cover and the panic hook assume one window, and iPhone Duo allows several.
        #expect(manifest["UIApplicationSupportsMultipleScenes"] as? Bool == false)
    }

    @Test func keepsLaunchStoryboard() throws {
        let plist = try Self.loadInfoPlist()
        // Builds against the iOS 27 SDK need a launch screen to pass App Store upload (TN3208).
        #expect(plist["UILaunchStoryboardName"] as? String == "LaunchScreen")
    }

    @Test func staysPortraitOnly() throws {
        let plist = try Self.loadInfoPlist()
        // Phone layouts are portrait-only; iPhone Duo's inner display ignores the lock and still fills the screen.
        #expect(plist["UISupportedInterfaceOrientations"] as? [String] == ["UIInterfaceOrientationPortrait"])
    }
}
