//
//  EncryptionStorage.swift
//  bitchat
//
//  Created by ~Akhtamov on 7/9/25.
//
import Foundation

protocol EncryptionStorage: BaseStorage {
    var identityKey : Data? { get set }
}

final class DefaultEncryptionStorage: EncryptionStorage {

    //MARK: - Properties
    private let storage: UserDefaults
    
    //MARK: - Init
    init(storage: UserDefaults = .standard) {
        self.storage = storage
    }
    
    enum EncryptionStorageKeys: String, UserDefaultsKeyProtocol {
        case identityKey = "bitchat.identityKey"
    }
    
    var identityKey: Data? {
        get { storage.data(forKey: EncryptionStorageKeys.identityKey.rawValue) }
        set { storage.set(newValue, forKey: EncryptionStorageKeys.identityKey.rawValue)}
    }
    
    func clear() {
        storage.removeObject(forKey: EncryptionStorageKeys.identityKey)
    }
    
    func synchronize() {
        storage.synchronize()
    }
}
