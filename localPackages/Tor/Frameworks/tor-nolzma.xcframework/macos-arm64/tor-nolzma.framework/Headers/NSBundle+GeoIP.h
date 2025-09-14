//
//  NSBundle+GeoIP.h
//  Tor
//
//  Created by Benjamin Erhart on 02.12.21.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSBundle (GeoIP)

@property (class, readonly, nullable) NSBundle *geoIpBundle;
@property (readonly, nullable) NSURL *geoipFile;
@property (readonly, nullable) NSURL *geoip6File;

@end

NS_ASSUME_NONNULL_END
