import Foundation

///
/// # StorageProtocol
///
/// A protocol that abstracts key–value storage in the project.
/// It makes it easier to save and retrieve values in memory, `UserDefaults`,
/// or any other type of key–value persistence.
///
protocol StorageProtocol {
    func set(_ value: Any?, key: String)
    func get<T>(_ key: String) -> T?
    func remove(_ key: String)
}

///
/// An implementation of that uses `UserDefaults` as a backing storage
/// for key–value storage.
///
final class UserDefaultsStorage: StorageProtocol {
    
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    convenience init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return nil
        }
        self.init(defaults: defaults)
    }
    
    func set(_ value: Any?, key: String) {
        defaults.set(value, forKey: key)
    }
    
    func get<T>(_ key: String) -> T? {
        defaults.object(forKey: key) as? T
    }
    
    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
