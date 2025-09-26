//
//  TORConfiguration.h
//  Tor
//
//  Created by Conrad Kramer on 8/10/15.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(TorConfiguration)
@interface TORConfiguration : NSObject

@property (nonatomic, copy, nullable) NSURL *dataDirectory;
@property (nonatomic, copy, nullable) NSURL *cacheDirectory;
@property (nonatomic, copy, nullable, readonly) NSURL *controlPortFile;
@property (nonatomic, copy, nullable) NSURL *controlSocket;
@property (nonatomic, copy, nullable) NSURL *socksURL;
@property (nonatomic) NSUInteger socksPort;
@property (nonatomic) NSUInteger dnsPort;
@property (nonatomic, copy, nullable) NSURL *clientAuthDirectory;
@property (nonatomic, copy, nullable) NSURL *hiddenServiceDirectory;
@property (nonatomic, copy, nullable, readonly) NSURL *serviceAuthDirectory;
@property (nonatomic, copy, nullable) NSURL *geoipFile;
@property (nonatomic, copy, nullable) NSURL *geoip6File;
@property (nonatomic, copy, nullable) NSURL *logfile;

@property (nonatomic) BOOL ignoreMissingTorrc;
@property (nonatomic) BOOL cookieAuthentication;
@property (nonatomic) BOOL autoControlPort;
@property (nonatomic) BOOL avoidDiskWrites;
@property (nonatomic) BOOL clientOnly;

@property (nonatomic, readonly) BOOL isLocked;
@property (nonatomic, copy, nullable, readonly) NSData *cookie;

@property (nonatomic, copy, null_resettable) NSMutableDictionary<NSString *, NSString *> *options;
@property (nonatomic, copy, null_resettable) NSMutableArray<NSString *> *arguments;

- (NSString *)valueOf:(NSString *)key;
- (NSArray<NSString *> *)compile;

@end

NS_ASSUME_NONNULL_END
