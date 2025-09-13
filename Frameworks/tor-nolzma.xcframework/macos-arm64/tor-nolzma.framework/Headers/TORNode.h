//
//  TORNode.h
//  Tor
//
//  Created by Benjamin Erhart on 09.12.19.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(TorNode)
@interface TORNode : NSObject<NSSecureCoding>

/**
Regular expression to identify and extract a valid IPv4 address.

Taken from https://nbviewer.jupyter.org/github/rasbt/python_reference/blob/master/tutorials/useful_regex.ipynb
*/
@property (class, nonatomic, readonly) NSRegularExpression *ipv4Regex;

/**
Regular expression to identify and extract a valid IPv6 address.

Taken from https://nbviewer.jupyter.org/github/rasbt/python_reference/blob/master/tutorials/useful_regex.ipynb
*/
@property (class, nonatomic, readonly) NSRegularExpression *ipv6Regex;

/**
 The fingerprint aka. ID of a Tor node.
 */
@property (nonatomic, nullable) NSString *fingerprint;

/**
 The nickname of a Tor node.
 */
@property (nonatomic, nullable) NSString *nickName;

/**
 The IPv4 address of a Tor node.
 */
@property (nonatomic, nullable) NSString *ipv4Address;

/**
 The IPv6 address of a Tor node.
 */
@property (nonatomic, nullable) NSString *ipv6Address;

/**
 The country code of a Tor node's country.
 */
@property (nonatomic, nullable) NSString *countryCode;

/**
 The localized country name of a Tor node's country.
 */
@property (nonatomic, readonly, nullable) NSString *localizedCountryName;

/**
 If this node can act as an exit node or not.
 */
@property BOOL isExit;

/**
 Create a `TORNode` object from a "LongName" node string which should contain the fingerprint and the nickname.

 See https://torproject.gitlab.io/torspec/control-spec.html#general-use-tokens

 @param longName A "LongName" identifying a Tor node.
 */
- (instancetype)initFromString:(NSString *)longName;

/**
 Creates a list of `TORNode` objects from the response of a `ns/[*]` call which should contain the nickname and IP address(es).

 See https://torproject.gitlab.io/torspec/control-spec.html#getinfo

 @param nsString Response from `ns/[*]` call, identifying one or more Tor nodes.
 @return a list of `TORNode`s discovered in the given string. Might be empty.
 */
+ (NSArray<TORNode *>  * _Nonnull)parseFromNsString:(NSString * _Nullable)nsString exitOnly:(BOOL)exitOnly;


/**
 Acquires IPv4 and IPv6 addresses from the given string.

 See https://torproject.gitlab.io/torspec/control-spec.html#getinfo

 @param response Should be the response of a `ns/id/<fingerprint>` call.
 */
- (void)acquireIpAddressesFromNsResponse:(NSString *)response;

@end

NS_ASSUME_NONNULL_END
