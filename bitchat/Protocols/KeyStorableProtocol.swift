import Foundation

///
/// # KeyStorable
///
/// A protocol that abstracts key–value storage in the project.
/// It makes it easier to save and retrieve values in memory, `UserDefaults`,
/// or any other type of key–value persistence.
///
protocol KeyStorable {
    func save(_ value: Any?, key: String)
    func data(_ key: String) -> Data?
    func string(_ key: String) -> String?
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
    
    func save(_ value: Any?, key: String) {
        defaults.set(value, forKey: key)
    }
    
    func data(_ key: String) -> Data? {
        defaults.data(forKey: key)
    }
    
    func string(_ key: String) -> String? {
        defaults.string(forKey: key)
    }
    
    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
