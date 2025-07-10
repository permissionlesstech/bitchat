//
//  AppStorage.swift
//  bitchat
//
//  Created by ~Akhtamov on 7/9/25.
//
import Foundation

protocol AppStorageUserDefaults: BaseStorage {
    var sharedContent: String? { get set }
    var sharedContentType: String? { get set }
    var sharedContentDate: Date? { get set }
    func removeObject(for key: DefaultAppStorage.AppStorageKeys) -> Void
}

final class DefaultAppStorage: AppStorageUserDefaults {
    private let storage: UserDefaults
    
    init(storage: UserDefaults = .standard) {
        self.storage = storage
    }
    
    init?(suiteName: String) {
    guard let storage = UserDefaults(suiteName: suiteName) else { return nil }
            self.storage = storage
    }
    
  enum AppStorageKeys: String, UserDefaultsKeyProtocol, CaseIterable {
        case sharedContentKey = "sharedContent"
        case sharedContentTypeKey = "sharedContentType"
        case sharedContentDateKey = "sharedContentDate"
    }
    
    var sharedContent: String? {
        get { storage.string(forKey: AppStorageKeys.sharedContentKey.rawValue)}
        set { storage.set(newValue, forKey: AppStorageKeys.sharedContentKey.rawValue)}
    }
    
    var sharedContentType: String? {
        get { storage.string(forKey: AppStorageKeys.sharedContentTypeKey.rawValue)}
        set { storage.set(newValue, forKey: AppStorageKeys.sharedContentTypeKey.rawValue)}
    }
    
    var sharedContentDate: Date? {
        get { storage.object(forKey: AppStorageKeys.sharedContentDateKey.rawValue) as? Date }
        set { storage.set(newValue, forKey: AppStorageKeys.sharedContentDateKey.rawValue)}
    }
    
    func clear() {
        AppStorageKeys.allCases.forEach { key in
            storage.removeObject(forKey: key.rawValue)
        }
        synchronize()
    }
    
    func removeObject(for key: AppStorageKeys) {
        storage.removeObject(forKey: key)
    }
    
    func synchronize() {
        storage.synchronize()
    }
}
