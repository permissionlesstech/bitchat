//
//  Untitled.swift
//  bitchat
//
//  Created by ~Akhtamov on 7/9/25.
//
import Foundation

protocol ChatStorage: BaseStorage {
    var savedNickName: String? { get set }
    var savedFavorites: [String]? { get set }
    var savedChannelsList: [String]? { get set }
    var savedProtectedChannels: [String]? { get set }
    var savedCreators: [String : String]? { get set }
    var savedCommitments: [String : String]? { get set }
    var savedRetentionChannels: [String]? { get set }
    var savedBlockedUsers: [String]? { get set }
    var favoriteChannels: [String]? { get set }
    func removeObject(for key: DefaultChatStorage.ChatStorageKeys) -> Void
}

final class DefaultChatStorage: ChatStorage {
    
    // MARK: - Properties
    private let storage: UserDefaults
    
    //MARK: - Init
    init(storage: UserDefaults = .standard) {
        self.storage = storage
    }
    
    enum ChatStorageKeys: String, UserDefaultsKeyProtocol {
        case nickNameKey = "bitchat.nickname"
        case favoritesKey = "bitchat.favorites"
        case joinedChannelsKey = "bitchat.joinedChannels"
        case passwordProtectedChannelsKey = "bitchat.passwordProtectedChannels"
        case channelCreatorsKey = "bitchat.channelCreators"
        case channelKeyCommitmentsKey = "bitchat.channelKeyCommitments"
        case retentionEnabledChannelsKey = "bitchat.retentionEnabledChannels"
        case blockedUsersKey = "bitchat.blockedUsers"
        case favoriteChannelsKey = "bitchat.favoriteChannels"
    }
    
    var savedNickName: String? {
        get { storage.string(forKey: ChatStorageKeys.nickNameKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.nickNameKey.rawValue)}
    }
    
    var savedFavorites: [String]? {
        get { storage.stringArray(forKey: ChatStorageKeys.favoritesKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.favoritesKey.rawValue)}
    }
    
    var savedChannelsList: [String]? {
        get { storage.stringArray(forKey: ChatStorageKeys.joinedChannelsKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.joinedChannelsKey.rawValue) }
    }
    
    var savedProtectedChannels: [String]? {
        get { storage.stringArray(forKey: ChatStorageKeys.passwordProtectedChannelsKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.passwordProtectedChannelsKey.rawValue)}
    }
    
    var savedCreators: [String : String]? {
        get { storage.dictionary(forKey: ChatStorageKeys.channelCreatorsKey.rawValue) as? [String : String]}
        set { storage.set(newValue, forKey: ChatStorageKeys.channelCreatorsKey.rawValue)}
    }
    
    var savedCommitments: [String : String]? {
        get { storage.dictionary(forKey: ChatStorageKeys.channelKeyCommitmentsKey.rawValue) as? [String : String]}
        set { storage.set(newValue, forKey: ChatStorageKeys.channelKeyCommitmentsKey.rawValue)}
    }
    
    var savedRetentionChannels: [String]? {
        get { storage.stringArray(forKey: ChatStorageKeys.retentionEnabledChannelsKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.retentionEnabledChannelsKey.rawValue)}
    }
    
    var savedBlockedUsers: [String]? {
        get { storage.stringArray(forKey: ChatStorageKeys.blockedUsersKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.blockedUsersKey.rawValue)}
    }
    
    var favoriteChannels: [String]? {
        get { storage.stringArray(forKey: ChatStorageKeys.favoriteChannelsKey.rawValue)}
        set { storage.set(newValue, forKey: ChatStorageKeys.favoriteChannelsKey.rawValue)}
    }
    
    func clear() {
        let keys: [ChatStorageKeys] = [.joinedChannelsKey, .passwordProtectedChannelsKey, .channelCreatorsKey, .channelKeyCommitmentsKey, .retentionEnabledChannelsKey]
        
        keys.forEach { key in
            storage.removeObject(forKey: key)
        }
    }
    
    func removeObject(for key: ChatStorageKeys) {
        storage.removeObject(forKey: key)
    }
    
    func synchronize() {
        storage.synchronize()
    }
}
