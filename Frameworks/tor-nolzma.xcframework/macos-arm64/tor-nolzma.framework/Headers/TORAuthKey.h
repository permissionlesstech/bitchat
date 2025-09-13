//
//  TORAuthKey.h
//  Tor
//
//  Created by Benjamin Erhart on 29.09.21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 The representation of one private or public v3 onion service authentication key.
 */
NS_SWIFT_NAME(TorAuthKey)
@interface TORAuthKey : NSObject

/**
 The location on disk, where this data was read from/will be written to.
 */
@property (nonatomic, readonly, nonnull) NSURL *file;

/**
 Flag, if this is a private (\c YES) or a public (\c NO) key.
 */
@property (atomic, readonly) BOOL isPrivate;

/**
 The full  onion service URL.
 */
@property (nonatomic, readonly, nullable) NSURL *onionAddress;

/**
 The authentication type.

Currently only the \c descriptor type is supported. This class will set this value hard for you.
 */
@property (nonatomic, readonly, nonnull) NSString *authType;

/**
 The key type.

 Currently only \c x25519 is supported. This class will set this value hard for you.
 Make sure, that the key you provide actually is of that type!
 */
@property (nonatomic, readonly, nonnull) NSString *keyType;

/**
 The actual public OR private key.

 This class doesn't enforce it, but Tor wants this to be in a BASE32 encoded format.

 Make sure, it is of the type \c x25519, as this is currently the only supported type by Tor and by this class!
 */
@property (nonatomic, readonly, nonnull) NSString *key;


/**
 Load from a key file on disk.

 See https://2019.www.torproject.org/docs/tor-manual.html.en#ClientOnionAuthDir
 and https://2019.www.torproject.org/docs/tor-manual.html.en#_client_authorization
 for the expected format.

 @param url The URL to the file containing the key. Expected to be in the correct format.
 */
- (instancetype)initFromUrl:(NSURL *)url;

/**
 Load from a key file on disk.

 See https://2019.www.torproject.org/docs/tor-manual.html.en#ClientOnionAuthDir
 and https://2019.www.torproject.org/docs/tor-manual.html.en#_client_authorization
 for the expected format.

 @param path The path to the file containing the key. Expected to be in the correct format.
 */
- (instancetype)initFromFile:(NSString *)path;

/**
 Create a new private key for a given domain.

 Normally, the domain will be used as file name, but this method will generate a UUID, if no domain can be found.

 @param key A \c BASE32 encoded \c x25519 private key.
 @param url A URL containing the v3 onion service domain for which this key is.
 */
- (instancetype)initPrivate:(NSString * _Nonnull)key forDomain:(NSURL * _Nonnull)url;

/**
 Create a new public key with the given name.

 The name wil be used as the file name.

 @param key A \c BASE32 encoded \c x25519 public key.
 @param name A name to identify this key to be used as the file name.
 */
- (instancetype)initPublic:(NSString * _Nonnull)key withName: (NSString *)name;


/**
 Set the base directory for the key.

 This needs to be called \b before \c persist, if you created a fresh key.

 @param directory The base directory where this key should be persisted.

 @see -persist
 */
- (void)setDirectory:(NSURL *)directory;

/**
 Persists this key to the file system.

 Call \c setDirectory:, if this instance wasn't created by reading a key from a file!

 @returns \c YES on success, \c NO on failure.

 @see -setDirectory:
 */
- (BOOL)persist;

/**
 Keys are considered equal, if their file URLs match.
 */
- (BOOL)isEqualToAuthKey:(TORAuthKey *)authKey;


/**
 Checks, if the given file name has the correct extension for either a private or public key.

 @param url A file URL to a key file.

 @returns \c YES, if this URL contains a key file extension.
 */
+ (BOOL)isAuthFile:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
