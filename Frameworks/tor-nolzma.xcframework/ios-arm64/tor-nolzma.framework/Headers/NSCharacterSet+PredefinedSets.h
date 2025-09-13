//
//  NSCharacterSet+PredefinedSets.h
//  Tor
//
//  Created by Benjamin Erhart on 12.12.19.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSCharacterSet (PredefinedSets)

@property (class, readonly) NSCharacterSet *doubleQuote;
@property (class, readonly) NSCharacterSet *longNameDivider;

@end

NS_ASSUME_NONNULL_END
