//
//  TORCircuit.h
//  Tor
//
//  Created by Benjamin Erhart on 11.12.19.
//
//  Documentation this class is modelled after:

//  https://gitlab.torproject.org/tpo/core/torspec/-/raw/main/control-spec.txt
//  Chapter 4.1.1 Circuit status changed

#import <Foundation/Foundation.h>
#import "TORNode.h"

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(TorCircuit)
@interface TORCircuit : NSObject<NSSecureCoding>

/**
 Regular expression to identify and extract ID, status and circuit path consisting of "LongNames".

 Syntax of node "LongNames":
 https://torproject.gitlab.io/torspec/control-spec.html#general-use-tokens
 */
@property (class, readonly) NSRegularExpression *mainInfoRegex;

/**
 - Tag: statusLaunched
 Circuit ID assigned to new circuit.
 */
@property (class, readonly) NSString *statusLaunched;

/**
 All hops finished, can now accept streams.
 */
@property (class, readonly) NSString *statusBuilt;

/**
 All hops finished, waiting to see if a circuit with a better guard will be usable.
 */
@property (class, readonly) NSString *statusGuardWait;

/**
 One more hop has been completed.
 */
@property (class, readonly) NSString *statusExtended;

/**
 Circuit closed (was not built).
 */
@property (class, readonly) NSString *statusFailed;

/**
 Circuit closed (was built).
 */
@property (class, readonly) NSString *statusClosed;

/**
 One-hop circuit, used for tunneled directory conns.
 */
@property (class, readonly) NSString *buildFlagOneHopTunnel;

/**
 Internal circuit, not to be used for exiting streams.
 */
@property (class, readonly) NSString *buildFlagIsInternal;

/**
 This circuit must use only high-capacity nodes.
 */
@property (class, readonly) NSString *buildFlagNeedCapacity;

/**
 This circuit must use only high-uptime nodes.
 */
@property (class, readonly) NSString *buildFlagNeedUptime;

/**
 Circuit for AP and/or directory request streams.
 */
@property (class, readonly) NSString *purposeGeneral;

/**
 HS client-side introduction-point circuit.
 */
@property (class, readonly) NSString *purposeHsClientIntro;

/**
 HS client-side rendezvous circuit; carries AP streams.
 */
@property (class, readonly) NSString *purposeHsClientRend;

/**
 HS service-side introduction-point circuit.
 */
@property (class, readonly) NSString *purposeHsServiceIntro;

/**
 HS service-side rendezvous circuit.
 */
@property (class, readonly) NSString *purposeHsServiceRend;

/**
 Circuit created ahead of time when using HS vanguards, and later repurposed as needed.
 */
@property (class, readonly) NSString *purposeHsVanguards;

/**
 Reachability-testing circuit; carries no traffic.
 */
@property (class, readonly) NSString *purposeTesting;

/**
 Circuit built by a controller.
 */
@property (class, readonly) NSString *purposeController;

/**
 Circuit being kept around to see how long it takes.
 */
@property (class, readonly) NSString *purposeMeasureTimeout;

/**
 Circuit is part of a conflux multi-path circuit set.

 https://tpo.pages.torproject.net/core/doc/tor/structcircuit__t.html#a7826adee26af5def133c43d2fe5f83fa
 */
@property (class, readonly) NSString *purposeConfluxLinked;

/**
 Circuit is in the pending pool usable in future circuit sets.

 https://tpo.pages.torproject.net/core/doc/tor/structcircuit__t.html#acabcbac5225591a5b7731a6994f438e4
 */
@property (class, readonly) NSString *purposeConfluxUnlinked;

/**
 Client-side introduction-point circuit state: Connecting to intro point.
 */
@property (class, readonly) NSString *hsStateHsciConnecting;

/**
 Client-side introduction-point circuit state: Sent INTRODUCE1; waiting for reply from IP.
 */
@property (class, readonly) NSString *hsStateHsciIntroSent;

/**
 Client-side introduction-point circuit state: Received reply from IP relay; closing.
 */
@property (class, readonly) NSString *hsStateHsciDone;

/**
 Client-side rendezvous-point circuit state: Connecting to or waiting for reply from RP.
 */
@property (class, readonly) NSString *hsStateHscrConnecting;

/**
 Client-side rendezvous-point circuit state: Established RP; waiting for introduction.
 */
@property (class, readonly) NSString *hsStateHscrEstablishedIdle;

/**
 Client-side rendezvous-point circuit state: Introduction sent to HS; waiting for rend.
 */
@property (class, readonly) NSString *hsStateHscrEstablishedWaiting;

/**
Client-side rendezvous-point circuit state: Connected to HS.
*/
@property (class, readonly) NSString *hsStateHscrJoined;

/**
 Service-side introduction-point circuit state: Connecting to intro point.
 */
@property (class, readonly) NSString *hsStateHssiConnecting;

/**
 Service-side introduction-point circuit state: Established intro point.
 */
@property (class, readonly) NSString *hsStateHssiEstablished;

/**
 Service-side rendezvous-point circuit state: Connecting to client's rend point.
 */
@property (class, readonly) NSString *hsStateHssrConnecting;

/**
 Service-side rendezvous-point circuit state: Connected to client's RP circuit.
 */
@property (class, readonly) NSString *hsStateHssrJoined;

/**
 No reason given.
 */
@property (class, readonly) NSString *reasonNone;

/**
 Tor protocol violation.
 */
@property (class, readonly) NSString *reasonTorProtocol;

/**
 Internal error.
 */
@property (class, readonly) NSString *reasonInternal;

/**
 A client sent a TRUNCATE command.
 */
@property (class, readonly) NSString *reasonRequested;

/**
 Not currently operating; trying to save bandwidth.
 */
@property (class, readonly) NSString *reasonHibernating;

/**
 Out of memory, sockets, or circuit IDs.
 */
@property (class, readonly) NSString *reasonResourceLimit;

/**
 Unable to reach relay.
 */
@property (class, readonly) NSString *reasonConnectFailed;

/**
 Connected to relay, but its OR identity was not as expected.
 */
@property (class, readonly) NSString *reasonOrIdentity;

/**
 The OR connection that was carrying this circuit died.
 */
@property (class, readonly) NSString *reasonOrConnClosed;

/**
 Circuit construction took too long.
 */
@property (class, readonly) NSString *reasonTimeout;

/**
 The circuit has expired for being dirty or old.
 */
@property (class, readonly) NSString *reasonFinished;

/**
 The circuit was destroyed w/o client TRUNCATE.
 */
@property (class, readonly) NSString *reasonDestroyed;

/**
 Not enough nodes to make circuit.
 */
@property (class, readonly) NSString *reasonNoPath;

/**
 Request for unknown hidden service.
 */
@property (class, readonly) NSString *reasonNoSuchService;

/**
 As @c reasonTimeout, except that we had left the circuit open for measurement purposes to see how long it would take to finish.
 */
@property (class, readonly) NSString *reasonMeasurementExpired;


/**
 The raw data this object is constructed from. The unchanged argument from @c initFromString:.
 */
@property (readonly, nullable) NSString *raw;

/**
The circuit ID. Currently only numbers beginning with "1" but Tor spec says, that could change.
 */
@property (readonly, nullable) NSString *circuitId;

/**
 The circuit status. Should be one of @c statusLaunched, @c statusBuilt, @c statusGuardWait,
 @c statusExtended, @c statusFailed or @c statusClosed .
 */
@property (readonly, nullable) NSString *status;

/**
 The circuit path as a list of @c TORNode objects.
 */
@property (readonly, nullable) NSArray<TORNode *> *nodes;

/**
 Build flags of the circuit. Can be any of @c buildFlagOneHopTunnel, @c buildFlagIsInternal,
 @c buildFlagNeedCapacity, @c buildFlagNeedUptime  or a flag which was unknown at the time of
 writing of this class.
*/
@property (readonly, nullable) NSArray<NSString *> *buildFlags;

/**
 Circuit purpose. May be one of @c purposeGeneral, @c purposeHsClientIntro,
 @c purposeHsClientRend, @c purposeHsServiceIntro, @c purposeHsServiceRend,
 @c purposeTesting, @c purposeController or, @c purposeMeasureTimeout.
 */
@property (readonly, nullable) NSString *purpose;

/**
 Circuit hidden service state. May be one of @c hsStateHsciConnecting, @c hsStateHsciIntroSent,
 @c hsStateHsciDone, @c hsStateHscrConnecting, @c hsStateHscrEstablishedIdle,
 @c hsStateHscrEstablishedWaiting, @c hsStateHscrJoined, @c hsStateHssiConnecting,
 @c hsStateHssiEstablished, @c hsStateHssrConnecting, @c hsStateHssrJoined
 or a state which was unknown at the time of writing of this class.
 */
@property (readonly, nullable) NSString *hsState;

/**
 The rendevouz query.

 Should be equal the onion address this circuit was used for minus the @c .onion postfix.
 */
@property (readonly, nullable) NSString *rendQuery;

/**
 The circuit's  timestamp at which the circuit was created or cannibalized.
 */
@property (readonly, nullable) NSDate *timeCreated;

/**
 The @c reason field is provided only for @c FAILED and @c CLOSED  events, and only if
 extended events are enabled.

 May be any one of @c reasonNone, @c reasonTorProtocol, @c reasonInternal,
 @c reasonRequested, @c reasonHibernating, @c reasonResourceLimit,
 @c reasonConnectFailed, @c reasonOrIdentity, @c reasonOrConnClosed,
 @c reasonTimeout, @c reasonFinished, @c reasonDestroyed, @c reasonNoPath,
 @c reasonNoSuchService, @c reasonMeasurementExpired  or a reason which was unknown at the
 time of writing of this class.
 */
@property (readonly, nullable) NSString *reason;

/**
 The @c remoteReason field is provided only when we receive a @c DESTROY or @c TRUNCATE cell, and
 only if extended events are enabled. It contains the actual reason given by the remote OR for closing the circuit.

 May be any one of @c reasonNone, @c reasonTorProtocol, @c reasonInternal,
 @c reasonRequested, @c reasonHibernating, @c reasonResourceLimit,
 @c reasonConnectFailed, @c reasonOrIdentity, @c reasonOrConnClosed,
 @c reasonTimeout, @c reasonFinished, @c reasonDestroyed, @c reasonNoPath,
 @c reasonNoSuchService, @c reasonMeasurementExpired  or a reason which was unknown at the
 time of writing of this class.
 */
@property (readonly, nullable) NSString *remoteReason;

/**
 The @c socksUsername and @c socksPassword fields indicate the credentials that were used by a
 SOCKS client to connect to Tor’s SOCKS port and initiate this circuit.
 */
@property (readonly, nullable) NSString *socksUsername;

/**
The @c socksUsername and @c socksPassword fields indicate the credentials that were used by a
SOCKS client to connect to Tor’s SOCKS port and initiate this circuit.
*/
@property (readonly, nullable) NSString *socksPassword;


/**
Extracts all circuit info from a string which should be the response to a "GETINFO circuit-status".

See https://torproject.gitlab.io/torspec/control-spec.html#getinfo

@param circuitsString A string as returned by "GETINFO circuit-status".
*/
+ (NSArray<TORCircuit *> *)circuitsFromString:(NSString *)circuitsString;


- (instancetype)initFromString:(NSString *)circuitString;


@end

NS_ASSUME_NONNULL_END
