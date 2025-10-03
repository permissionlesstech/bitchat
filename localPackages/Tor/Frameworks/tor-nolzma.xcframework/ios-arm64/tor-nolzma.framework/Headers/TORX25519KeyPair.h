//
//  TORX25519KeyPair.h
//  Tor
//
//  Created by Benjamin Erhart on 11.10.21.
//

#import <Foundation/Foundation.h>
#import "TORAuthKey.h"

NS_ASSUME_NONNULL_BEGIN

/**
 Class to generate or hold a X25519 public/private key pair encoded in BASE32.
 */
NS_SWIFT_NAME(TorX25519KeyPair)
@interface TORX25519KeyPair : NSObject


/**
 The BASE32 encoded private key. Should be exactly 32 bytes long, resp. 52 characters in BASE32 encoding.
 */
@property (nonatomic, nullable, readonly) NSString *privateKey;

/**
 The BASE32 encoded public key. Should be exactly 32 bytes long, resp. 52 characters in BASE32 encoding.
 */
@property (nonatomic, nullable, readonly) NSString *publicKey;


/**
 Generate a new X25519 key pair using Tor's implementation.

 On iOS 13 and up, another option is also available: CryptoKit's \c Curve25519.KeyAggreement.PrivateKey
 */
- (instancetype)init;

/**
 Initialize with a pre-generated, BASE32-encoded X25519 key pair. A valid key pair is exactly 32 bytes long,
 resp. 52 characters in BASE32 encoding.

 No validity checks are made! It's your responsibility to provide valid key material.

 @param privateKey The private key, BASE32 encoded.
 @param publicKey The public key, BASE32 encoded.
 */
- (instancetype)initWithBase32PrivateKey:(NSString *)privateKey andPublicKey:(NSString *)publicKey;

/**
 Initialize with a pre-generated X25519 key pair. A valid key pair is exactly 32 bytes long.

 No validity checks are made! It's your responsibility to provide valid key material.

 @param privateKey The private key.
 @param publicKey The public key.
  */
- (instancetype)initWithPrivateKey:(NSData *)privateKey andPublicKey:(NSData *)publicKey;


/**
 Create a private \c TORAuthKey from this key material using the provided domain.

 @param domain The domain name, this private key is for. Must include the \c .onion TLD!
 @returns the private \c TORAuthKey of this key pair's private key  or \c nil if the \c domain is empty or this class doesn't contain a private key.
*/
- (nullable TORAuthKey *)getPrivateAuthKeyForDomain:(nonnull NSString *)domain;

/**
 Create a private \c TORAuthKey from this key material using the provided domain.

 @param url The domain, this private key is for.
 @returns the private \c TORAuthKey of this key pair's private key  or \c nil if this class doesn't contain a private key.
*/
- (nullable TORAuthKey *)getPrivateAuthKeyForUrl:(nonnull NSURL *)url;

/**
 Create a public \c TORAuthKey from this key material using the provided name.

 @param name The name used to store that \c TORAuthKey, without the extension!
 @returns the public \c TORAuthKey of this key pair's public key or \c nil if the \c name is empty or this class doesn't contain a public key.
 */
- (nullable TORAuthKey *)getPublicAuthKeyWithName:(nonnull NSString *)name;


/**
 Helper method to BASE32 encode raw binary \c NSData into a \c NSString.

 @param raw The raw binary \c NSData to encode.
 @returns a BASE32 encoded representation of that binary data.
 */
+ (nullable NSString *)base32Encode:(NSData *)raw;

/**
 Helper method to decode raw binary \c NSData contained in a BASE32 encoded \c NSString.

 @param encoded The BASE32 encoded data  to decode.
 @returns binary data.
 */
+ (nullable NSData *)base32Decode:(NSString *)encoded;


@end

NS_ASSUME_NONNULL_END
