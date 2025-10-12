@testable import bitchat

final class UserDefaultsStorageMock: StorageProtocol {
    
    private var persistences: [String: Any] = [:]
    
    func set(_ value: Any?, key: String) {
        persistences[key] = value
    }
    
    func get<T>(_ key: String) -> T? {
        persistences[key] as? T
    }
    
    func remove(_ key: String) {
        persistences.removeValue(forKey: key)
    }
}
