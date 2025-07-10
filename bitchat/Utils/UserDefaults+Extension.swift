//
//  UserDefaults+Extension.swift
//  bitchat
//
//  Created by ~Akhtamov on 7/9/25.
//

import Foundation

protocol UserDefaultsKeyProtocol {
    var rawValue: String { get }
}

extension UserDefaults {
    
    func saveObject<Object: Codable>(_ object: Object?, forKey key: UserDefaultsKeyProtocol) {
        if object == nil {
            self.setValue(nil, forKey: key.rawValue)
            return
        }
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(object) {
            self.set(encoded, forKey: key.rawValue)
        }
    }
    
    func getObject<Object: Codable>(_ type: Object.Type, forKey key: UserDefaultsKeyProtocol) -> Object? {
        guard let savedObject = self.value(forKey: key.rawValue) as? Data else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(Object.self, from: savedObject)
    }
    
    func removeObject(forKey key: UserDefaultsKeyProtocol) {
        self.removeObject(forKey: key.rawValue)
    }

}
