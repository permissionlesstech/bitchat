import UIKit

/// iOS relaunches the app in the background, with no screen, when Bluetooth activity happens after the system had
/// terminated it (state restoration). The mesh must therefore start here and not only when the first screen appears.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if UserDefaults.standard.bool(forKey: "onboarded") {      // Bluetooth permission has been asked for
            MainActor.assumeIsolated { ChatStore.shared.startIfNeeded() }
        }
        return true
    }
}
