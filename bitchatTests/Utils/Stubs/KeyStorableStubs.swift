@testable import bitchat

final class UserDefaultsKeyStorableStub: KeyStorable {
    
    private var persistences: [String: Any] = [:]
    
    func set(_ value: Any?, key: String) {
        persistences[key] = value
    }
    
    func get<T>(key: String) -> T? {
        persistences[key] as? T
    }
    
    func remove(_ key: String) {
        persistences.removeValue(forKey: key)
    }
}
