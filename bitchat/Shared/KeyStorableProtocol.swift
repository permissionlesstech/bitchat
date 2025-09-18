import Foundation

///
/// # KeyStorable
///
/// A protocol that abstracts key–value storage in the project.
/// It makes it easier to save and retrieve values in memory, `UserDefaults`,
/// or any other type of key–value persistence.
///
protocol KeyStorable {
    func set(_ value: Any?, key: String)
    func get<T>(key: String) -> T?
    func remove(_ key: String)
}

///
/// An implementation of `KeyStorable` that uses the standard `UserDefaults`
/// for key–value storage.
///
final class UserDefaultsKeyStorable: KeyStorable {
    
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    func set(_ value: Any?, key: String) {
        defaults.set(value, forKey: key)
    }
    
    func get<T>(key: String) -> T? {
        defaults.object(forKey: key) as? T
    }
    
    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
