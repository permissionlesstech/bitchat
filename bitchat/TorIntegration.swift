import Foundation
import TorManager

extension TorManager {
    // Provide a single shared instance with a cache directory for Tor state.
    static let shared: TorManager = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tor", isDirectory: true)
        return TorManager(directory: dir)
    }()
}
