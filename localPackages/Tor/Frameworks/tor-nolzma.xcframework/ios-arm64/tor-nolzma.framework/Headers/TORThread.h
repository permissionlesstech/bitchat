//
//  TORThread.h
//  Tor
//
//  Created by Conrad Kramer on 7/19/15.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TORConfiguration;

NS_SWIFT_NAME(TorThread)
@interface TORThread : NSThread

#if __has_feature(objc_class_property)
@property (class, readonly, nullable) TORThread *activeThread;
#else
+ (nullable TORThread *)activeThread;
#endif

- (instancetype)initWithConfiguration:(nullable TORConfiguration *)configuration;
- (instancetype)initWithArguments:(nullable NSArray<NSString *> *)arguments NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
