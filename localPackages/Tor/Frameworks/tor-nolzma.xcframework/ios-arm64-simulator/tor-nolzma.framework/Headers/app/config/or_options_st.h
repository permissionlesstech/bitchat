/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file or_options_st.h
 *
 * \brief The or_options_t structure, which represents Tor's configuration.
 */

#ifndef TOR_OR_OPTIONS_ST_H
#define TOR_OR_OPTIONS_ST_H

#include "core/or/or.h"
#include "lib/cc/torint.h"
#include "lib/net/address.h"
#include "app/config/tor_cmdline_mode.h"

struct smartlist_t;
struct config_line_t;
struct config_suite_t;
struct routerset_t;

/** Enumeration of outbound address configuration types:
 * Exit-only, OR-only, PT-only, or any of them */
typedef enum {
  /** Outbound IP address for Exit connections. Controlled by the
   * `OutboundBindAddressExit` configuration entry in torrc. */
  OUTBOUND_ADDR_EXIT,

  /** Outbound IP address for OR connections. Controlled by the
   * `OutboundBindAddressOR` configuration entry in torrc. */
  OUTBOUND_ADDR_OR,

  /** Outbound IP address for PT connections. Controlled by the
   * `OutboundBindAddressPT` configuration entry in torrc. */
  OUTBOUND_ADDR_PT,

  /** Outbound IP address for any outgoing connections. Controlled by the
   * OutboundBindAddress configuration entry in torrc. This value is used as
   * fallback if the more specific OUTBOUND_ADDR_EXIT, OUTBOUND_ADDR_OR, and
   * OUTBOUND_ADDR_PT are unset. */
  OUTBOUND_ADDR_ANY,

  /** Max value for this enum. Must be the last element in this enum. */
  OUTBOUND_ADDR_MAX
} outbound_addr_t;

/** Which protocol to use for TCPProxy. */
typedef enum {
  /** Use the HAProxy proxy protocol. */
  TCP_PROXY_PROTOCOL_HAPROXY
} tcp_proxy_protocol_t;

/** Enumeration of available time formats for output of --key-expiration */
typedef enum {
  KEY_EXPIRATION_FORMAT_ISO8601 = 0,
  KEY_EXPIRATION_FORMAT_TIMESTAMP
} key_expiration_format_t;

/** Configuration options for a Tor process. */
struct or_options_t {
  uint32_t magic_;

  /** What should the tor process actually do? */
  tor_cmdline_mode_t command;
  char *command_arg; /**< Argument for command-line option. */

  struct config_line_t *Logs; /**< New-style list of configuration lines
                        * for logs */
  int LogTimeGranularity; /**< Log resolution in milliseconds. */

  int LogMessageDomains; /**< Boolean: Should we log the domain(s) in which
                          * each log message occurs? */
  int TruncateLogFile; /**< Boolean: Should we truncate the log file
                            before we start writing? */
  char *SyslogIdentityTag; /**< Identity tag to add for syslog logging. */

  char *DebugLogFile; /**< Where to send verbose log messages. */
  char *DataDirectory_option; /**< Where to store long-term data, as
                               * configured by the user. */
  char *DataDirectory; /**< Where to store long-term data, as modified. */
  int DataDirectoryGroupReadable; /**< Boolean: Is the DataDirectory g+r? */

  char *KeyDirectory_option; /**< Where to store keys, as
                               * configured by the user. */
  char *KeyDirectory; /**< Where to store keys data, as modified. */
  int KeyDirectoryGroupReadable; /**< Boolean: Is the KeyDirectory g+r? */

  char *CacheDirectory_option; /**< Where to store cached data, as
                               * configured by the user. */
  char *CacheDirectory; /**< Where to store cached data, as modified. */
  int CacheDirectoryGroupReadable; /**< Boolean: Is the CacheDirectory g+r? */

  char *Nickname; /**< OR only: nickname of this onion router. */
  /** OR only: configured address for this onion router. Up to two times this
   * options is accepted as in IPv4 and IPv6. */
  struct config_line_t *Address;

  /** Boolean: If set, disable IPv6 address resolution, IPv6 ORPorts, IPv6
   * reachability checks, and publishing an IPv6 ORPort in its descriptor. */
  int AddressDisableIPv6;

  char *PidFile; /**< Where to store PID of Tor process. */

  struct routerset_t *ExitNodes; /**< Structure containing nicknames, digests,
                           * country codes and IP address patterns of ORs to
                           * consider as exits. */
  struct routerset_t *MiddleNodes; /**< Structure containing nicknames,
                             * digests, country codes and IP address patterns
                             * of ORs to consider as middles. */
  struct routerset_t *EntryNodes;/**< Structure containing nicknames, digests,
                           * country codes and IP address patterns of ORs to
                           * consider as entry points. */
  int StrictNodes; /**< Boolean: When none of our EntryNodes or ExitNodes
                    * are up, or we need to access a node in ExcludeNodes,
                    * do we just fail instead? */
  struct routerset_t *ExcludeNodes;/**< Structure containing nicknames,
                             * digests, country codes and IP address patterns
                             * of ORs not to use in circuits. But see
                             * StrictNodes above. */
  struct routerset_t *ExcludeExitNodes;/**< Structure containing nicknames,
                                 * digests, country codes and IP address
                                 * patterns of ORs not to consider as
                                 * exits. */

  /** Union of ExcludeNodes and ExcludeExitNodes */
  struct routerset_t *ExcludeExitNodesUnion_;

  int DisableAllSwap; /**< Boolean: Attempt to call mlockall() on our
                       * process for all current and future memory. */

  struct config_line_t *ExitPolicy; /**< Lists of exit policy components. */
  int ExitPolicyRejectPrivate; /**< Should we not exit to reserved private
                                * addresses, and our own published addresses?
                                */
  int ExitPolicyRejectLocalInterfaces; /**< Should we not exit to local
                                        * interface addresses?
                                        * Includes OutboundBindAddresses and
                                        * configured ports. */
  int ReducedExitPolicy; /**<Should we use the Reduced Exit Policy? */
  struct config_line_t *SocksPolicy; /**< Lists of socks policy components */
  struct config_line_t *DirPolicy; /**< Lists of dir policy components */
  /** Local address to bind outbound sockets */
  struct config_line_t *OutboundBindAddress;
  /** Local address to bind outbound relay sockets */
  struct config_line_t *OutboundBindAddressOR;
  /** Local address to bind outbound exit sockets */
  struct config_line_t *OutboundBindAddressExit;
  /** Local address to bind outbound PT sockets */
  struct config_line_t *OutboundBindAddressPT;
  /** Addresses derived from the various OutboundBindAddress lines.
   * [][0] is IPv4, [][1] is IPv6
   */
  tor_addr_t OutboundBindAddresses[OUTBOUND_ADDR_MAX][2];
  /** Whether dirservers allow router descriptors with private IPs. */
  int DirAllowPrivateAddresses;
  /** Whether routers accept EXTEND cells to routers with private IPs. */
  int ExtendAllowPrivateAddresses;
  char *User; /**< Name of user to run Tor as. */
   /** Ports to listen on for OR connections. */
  struct config_line_t *ORPort_lines;
  /** Ports to listen on for extended OR connections. */
  struct config_line_t *ExtORPort_lines;
  /** Ports to listen on for Metrics connections. */
  struct config_line_t *MetricsPort_lines;
  /** Ports to listen on for SOCKS connections. */
  struct config_line_t *SocksPort_lines;
  /** Ports to listen on for transparent pf/netfilter connections. */
  struct config_line_t *TransPort_lines;
  char *TransProxyType; /**< What kind of transparent proxy
                         * implementation are we using? */
  /** Parsed value of TransProxyType. */
  enum {
    TPT_DEFAULT,
    TPT_PF_DIVERT,
    TPT_IPFW,
    TPT_TPROXY,
  } TransProxyType_parsed;
  /** Ports to listen on for transparent natd connections. */
  struct config_line_t *NATDPort_lines;
  /** Ports to listen on for HTTP Tunnel connections. */
  struct config_line_t *HTTPTunnelPort_lines;
  struct config_line_t *ControlPort_lines; /**< Ports to listen on for control
                               * connections. */
  /** List of Unix Domain Sockets to listen on for control connections. */
  struct config_line_t *ControlSocket;

  int ControlSocketsGroupWritable; /**< Boolean: Are control sockets g+rw? */
  int UnixSocksGroupWritable; /**< Boolean: Are SOCKS Unix sockets g+rw? */
  /** Ports to listen on for directory connections. */
  struct config_line_t *DirPort_lines;
  /** Ports to listen on for DNS requests. */
  struct config_line_t *DNSPort_lines;

  /* MaxMemInQueues value as input by the user. We clean this up to be
   * MaxMemInQueues. */
  uint64_t MaxMemInQueues_raw;
  uint64_t MaxMemInQueues;/**< If we have more memory than this allocated
                            * for queues and buffers, run the OOM handler */
  /** Above this value, consider ourselves low on RAM. */
  uint64_t MaxMemInQueues_low_threshold;

  /** @name port booleans
   *
   * Derived booleans: For server ports and ControlPort, true iff there is a
   * non-listener port on an AF_INET or AF_INET6 address of the given type
   * configured in one of the _lines options above.
   * For client ports, also true if there is a unix socket configured.
   * If you are checking for client ports, you may want to use:
   *   SocksPort_set || TransPort_set || NATDPort_set || DNSPort_set ||
   *   HTTPTunnelPort_set
   * rather than SocksPort_set.
   *
   * @{
   */
  unsigned int ORPort_set : 1;
  unsigned int SocksPort_set : 1;
  unsigned int TransPort_set : 1;
  unsigned int NATDPort_set : 1;
  unsigned int ControlPort_set : 1;
  unsigned int DirPort_set : 1;
  unsigned int DNSPort_set : 1;
  unsigned int ExtORPort_set : 1;
  unsigned int HTTPTunnelPort_set : 1;
  unsigned int MetricsPort_set : 1;
  /**@}*/

  /** Whether to publish our descriptor regardless of all our self-tests
   */
  int AssumeReachable;
  /** Whether to publish our descriptor regardless of IPv6 self-tests.
   *
   * This is an autobool; when set to AUTO, it uses AssumeReachable.
   **/
  int AssumeReachableIPv6;
  int AuthoritativeDir; /**< Boolean: is this an authoritative directory? */
  int V3AuthoritativeDir; /**< Boolean: is this an authoritative directory
                           * for version 3 directories? */
  int BridgeAuthoritativeDir; /**< Boolean: is this an authoritative directory
                               * that aggregates bridge descriptors? */

  /** If set on a bridge relay, it will include this value on a new
   * "bridge-distribution-request" line in its bridge descriptor. */
  char *BridgeDistribution;

  /** If set on a bridge authority, it will answer requests on its dirport
   * for bridge statuses -- but only if the requests use this password. */
  char *BridgePassword;
  /** If BridgePassword is set, this is a SHA256 digest of the basic http
   * authenticator for it. Used so we can do a time-independent comparison. */
  char *BridgePassword_AuthDigest_;

  int UseBridges; /**< Boolean: should we start all circuits with a bridge? */
  struct config_line_t *Bridges; /**< List of bootstrap bridge addresses. */

  struct config_line_t *ClientTransportPlugin; /**< List of client
                                           transport plugins. */

  struct config_line_t *ServerTransportPlugin; /**< List of client
                                           transport plugins. */

  /** List of TCP/IP addresses that transports should listen at. */
  struct config_line_t *ServerTransportListenAddr;

  /** List of options that must be passed to pluggable transports. */
  struct config_line_t *ServerTransportOptions;

  int BridgeRelay; /**< Boolean: are we acting as a bridge relay? We make
                    * this explicit so we can change how we behave in the
                    * future. */

  /** Boolean: if we know the bridge's digest, should we get new
   * descriptors from the bridge authorities or from the bridge itself? */
  int UpdateBridgesFromAuthority;

  int AvoidDiskWrites; /**< Boolean: should we never cache things to disk?
                        * Not used yet. */
  int ClientOnly; /**< Boolean: should we never evolve into a server role? */

  int ReducedConnectionPadding; /**< Boolean: Should we try to keep connections
                                  open shorter and pad them less against
                                  connection-level traffic analysis? */
  /** Autobool: if auto, then connection padding will be negotiated by client
   * and server. If 0, it will be fully disabled. If 1, the client will still
   * pad to the server regardless of server support. */
  int ConnectionPadding;

  /** Boolean: if true, then circuit padding will be negotiated by client
   * and server, subject to consenus limits (default). If 0, it will be fully
   * disabled. */
  int CircuitPadding;

  /** Boolean: if true, then this client will discard cached bridge
   * descriptors on a setconf or other config change that impacts guards
   * or bridges (see options_transition_affects_guards() for exactly which
   * config changes trigger it). Useful for tools that test bridge
   * reachability by fetching fresh descriptors. */
  int ReconfigDropsBridgeDescs;

  /** Boolean: if true, then this client will only use circuit padding
   * algorithms that are known to use a low amount of overhead. If false,
   * we will use all available circuit padding algorithms.
   */
  int ReducedCircuitPadding;

  /** To what authority types do we publish our descriptor? Choices are
   * "v1", "v2", "v3", "bridge", or "". */
  struct smartlist_t *PublishServerDescriptor;
  /** A bitfield of authority types, derived from PublishServerDescriptor. */
  dirinfo_type_t PublishServerDescriptor_;
  /** Boolean: do we publish hidden service descriptors to the HS auths? */
  int PublishHidServDescriptors;
  int FetchServerDescriptors; /**< Do we fetch server descriptors as normal? */
  int FetchHidServDescriptors; /**< and hidden service descriptors? */

  int FetchUselessDescriptors; /**< Do we fetch non-running descriptors too? */
  int AllDirActionsPrivate; /**< Should every directory action be sent
                             * through a Tor circuit? */

  /** A routerset that should be used when picking middle nodes for HS
   *  circuits. */
  struct routerset_t *HSLayer2Nodes;

  /** A routerset that should be used when picking third-hop nodes for HS
   *  circuits. */
  struct routerset_t *HSLayer3Nodes;

  /** Onion Services in HiddenServiceSingleHopMode make one-hop (direct)
   * circuits between the onion service server, and the introduction and
   * rendezvous points. (Onion service descriptors are still posted using
   * 3-hop paths, to avoid onion service directories blocking the service.)
   * This option makes every hidden service instance hosted by
   * this tor instance a Single Onion Service.
   * HiddenServiceSingleHopMode requires HiddenServiceNonAnonymousMode to be
   * set to 1.
   * Use rend_service_allow_non_anonymous_connection() or
   * rend_service_reveal_startup_time() instead of using this option directly.
   */
  int HiddenServiceSingleHopMode;
  /* Makes hidden service clients and servers non-anonymous on this tor
   * instance. Allows the non-anonymous HiddenServiceSingleHopMode. Enables
   * non-anonymous behaviour in the hidden service protocol.
   * Use hs_service_non_anonymous_mode_enabled() instead of using this option
   * directly.
   */
  int HiddenServiceNonAnonymousMode;

  int ConnLimit; /**< Demanded minimum number of simultaneous connections. */
  int ConnLimit_; /**< Maximum allowed number of simultaneous connections. */
  int ConnLimit_high_thresh; /**< start trying to lower socket usage if we
                              *   have this many. */
  int ConnLimit_low_thresh; /**< try to get down to here after socket
                             *   exhaustion. */
  int RunAsDaemon; /**< If true, run in the background. (Unix only) */
  int FascistFirewall; /**< Whether to prefer ORs reachable on open ports. */
  struct smartlist_t *FirewallPorts; /**< Which ports our firewall allows
                               * (strings). */
   /** IP:ports our firewall allows. */
  struct config_line_t *ReachableAddresses;
  struct config_line_t *ReachableORAddresses; /**< IP:ports for OR conns. */
  struct config_line_t *ReachableDirAddresses; /**< IP:ports for Dir conns. */

  int ConstrainedSockets; /**< Shrink xmit and recv socket buffers. */
  uint64_t ConstrainedSockSize; /**< Size of constrained buffers. */

  /** Whether we should drop exit streams from Tors that we don't know are
   * relays.  One of "0" (never refuse), "1" (always refuse), or "-1" (do
   * what the consensus says, defaulting to 'refuse' if the consensus says
   * nothing). */
  int RefuseUnknownExits;

  /** Application ports that require all nodes in circ to have sufficient
   * uptime. */
  struct smartlist_t *LongLivedPorts;
  /** Application ports that are likely to be unencrypted and
   * unauthenticated; we reject requests for them to prevent the
   * user from screwing up and leaking plaintext secrets to an
   * observer somewhere on the Internet. */
  struct smartlist_t *RejectPlaintextPorts;
  /** Related to RejectPlaintextPorts above, except this config option
   * controls whether we warn (in the log and via a controller status
   * event) every time a risky connection is attempted. */
  struct smartlist_t *WarnPlaintextPorts;
  /** Should we try to reuse the same exit node for a given host */
  struct smartlist_t *TrackHostExits;
  int TrackHostExitsExpire; /**< Number of seconds until we expire an
                             * addressmap */
  struct config_line_t *AddressMap; /**< List of address map directives. */
  int AutomapHostsOnResolve; /**< If true, when we get a resolve request for a
                              * hostname ending with one of the suffixes in
                              * <b>AutomapHostsSuffixes</b>, map it to a
                              * virtual address. */
  /** List of suffixes for <b>AutomapHostsOnResolve</b>.  The special value
   * "." means "match everything." */
  struct smartlist_t *AutomapHostsSuffixes;
  int KeepalivePeriod; /**< How often do we send padding cells to keep
                        * connections alive? */
  int SocksTimeout; /**< How long do we let a socks connection wait
                     * unattached before we fail it? */
  int LearnCircuitBuildTimeout; /**< If non-zero, we attempt to learn a value
                                 * for CircuitBuildTimeout based on timeout
                                 * history. Use circuit_build_times_disabled()
                                 * rather than checking this value directly. */
  int CircuitBuildTimeout; /**< Cull non-open circuits that were born at
                            * least this many seconds ago. Used until
                            * adaptive algorithm learns a new value. */
  int CircuitsAvailableTimeout; /**< Try to have an open circuit for at
                                     least this long after last activity */
  int CircuitStreamTimeout; /**< If non-zero, detach streams from circuits
                             * and try a new circuit if the stream has been
                             * waiting for this many seconds. If zero, use
                             * our default internal timeout schedule. */
  int MaxOnionQueueDelay; /*< DOCDOC */
  int NewCircuitPeriod; /**< How long do we use a circuit before building
                         * a new one? */
  int MaxCircuitDirtiness; /**< Never use circs that were first used more than
                                this interval ago. */
  uint64_t BandwidthRate; /**< How much bandwidth, on average, are we willing
                           * to use in a second? */
  uint64_t BandwidthBurst; /**< How much bandwidth, at maximum, are we willing
                            * to use in a second? */
  uint64_t MaxAdvertisedBandwidth; /**< How much bandwidth are we willing to
                                    * tell other nodes we have? */
  uint64_t RelayBandwidthRate; /**< How much bandwidth, on average, are we
                                 * willing to use for all relayed conns? */
  uint64_t RelayBandwidthBurst; /**< How much bandwidth, at maximum, will we
                                 * use in a second for all relayed conns? */
  uint64_t PerConnBWRate; /**< Long-term bw on a single TLS conn, if set. */
  uint64_t PerConnBWBurst; /**< Allowed burst on a single TLS conn, if set. */
  int NumCPUs; /**< How many CPUs should we try to use? */
  struct config_line_t *RendConfigLines; /**< List of configuration lines
                                          * for rendezvous services. */
  char *ClientOnionAuthDir; /**< Directory to keep client
                             * onion service authorization secret keys */
  char *ContactInfo; /**< Contact info to be published in the directory. */

  int HeartbeatPeriod; /**< Log heartbeat messages after this many seconds
                        * have passed. */
  int MainloopStats; /**< Log main loop statistics as part of the
                      * heartbeat messages. */

  char *HTTPProxy; /**< hostname[:port] to use as http proxy, if any. */
  tor_addr_t HTTPProxyAddr; /**< Parsed IPv4 addr for http proxy, if any. */
  uint16_t HTTPProxyPort; /**< Parsed port for http proxy, if any. */
  char *HTTPProxyAuthenticator; /**< username:password string, if any. */

  char *HTTPSProxy; /**< hostname[:port] to use as https proxy, if any. */
  tor_addr_t HTTPSProxyAddr; /**< Parsed addr for https proxy, if any. */
  uint16_t HTTPSProxyPort; /**< Parsed port for https proxy, if any. */
  char *HTTPSProxyAuthenticator; /**< username:password string, if any. */

  char *Socks4Proxy; /**< hostname:port to use as a SOCKS4 proxy, if any. */
  tor_addr_t Socks4ProxyAddr; /**< Derived from Socks4Proxy. */
  uint16_t Socks4ProxyPort; /**< Derived from Socks4Proxy. */

  char *Socks5Proxy; /**< hostname:port to use as a SOCKS5 proxy, if any. */
  tor_addr_t Socks5ProxyAddr; /**< Derived from Sock5Proxy. */
  uint16_t Socks5ProxyPort; /**< Derived from Socks5Proxy. */
  char *Socks5ProxyUsername; /**< Username for SOCKS5 authentication, if any */
  char *Socks5ProxyPassword; /**< Password for SOCKS5 authentication, if any */

  char *TCPProxy; /**< protocol and hostname:port to use as a proxy, if any. */
  tcp_proxy_protocol_t TCPProxyProtocol; /**< Derived from TCPProxy. */
  tor_addr_t TCPProxyAddr; /**< Derived from TCPProxy. */
  uint16_t TCPProxyPort; /**< Derived from TCPProxy. */

  /** List of configuration lines for replacement directory authorities.
   * If you just want to replace one class of authority at a time,
   * use the "Alternate*Authority" options below instead. */
  struct config_line_t *DirAuthorities;

  /** List of fallback directory servers */
  struct config_line_t *FallbackDir;
  /** Whether to use the default hard-coded FallbackDirs */
  int UseDefaultFallbackDirs;

  /** Weight to apply to all directory authority rates if considering them
   * along with fallbackdirs */
  double DirAuthorityFallbackRate;

  /** If set, use these main (currently v3) directory authorities and
   * not the default ones. */
  struct config_line_t *AlternateDirAuthority;

  /** If set, use these bridge authorities and not the default one. */
  struct config_line_t *AlternateBridgeAuthority;

  struct config_line_t *MyFamily_lines; /**< Declared family for this OR. */
  struct config_line_t *MyFamily; /**< Declared family for this OR,
                                     normalized */
  struct config_line_t *NodeFamilies; /**< List of config lines for
                                * node families */
  /** List of parsed NodeFamilies values. */
  struct smartlist_t *NodeFamilySets;
  struct config_line_t *AuthDirBadExit; /**< Address policy for descriptors to
                                  * mark as bad exits. */
  /** Address policy for descriptors to mark as only suitable for the
   * middle position in circuits. */
  struct config_line_t *AuthDirMiddleOnly;
  struct config_line_t *AuthDirReject; /**< Address policy for descriptors to
                                 * reject. */
  struct config_line_t *AuthDirInvalid; /**< Address policy for descriptors to
                                  * never mark as valid. */
  /** @name AuthDir...CC
   *
   * Lists of country codes to mark as BadExit, or Invalid, or to
   * reject entirely.
   *
   * @{
   */
  struct smartlist_t *AuthDirBadExitCCs;
  struct smartlist_t *AuthDirInvalidCCs;
  struct smartlist_t *AuthDirMiddleOnlyCCs;
  struct smartlist_t *AuthDirRejectCCs;
  /**@}*/

  char *AccountingStart; /**< How long is the accounting interval, and when
                          * does it start? */
  uint64_t AccountingMax; /**< How many bytes do we allow per accounting
                           * interval before hibernation?  0 for "never
                           * hibernate." */
  /** How do we determine when our AccountingMax has been reached?
   * "max" for when in or out reaches AccountingMax
   * "sum" for when in plus out reaches AccountingMax
   * "in"  for when in reaches AccountingMax
   * "out" for when out reaches AccountingMax */
  char *AccountingRule_option;
  enum { ACCT_MAX, ACCT_SUM, ACCT_IN, ACCT_OUT } AccountingRule;

  /** Base64-encoded hash of accepted passwords for the control system. */
  struct config_line_t *HashedControlPassword;
  /** As HashedControlPassword, but not saved. */
  struct config_line_t *HashedControlSessionPassword;

  int CookieAuthentication; /**< Boolean: do we enable cookie-based auth for
                             * the control system? */
  char *CookieAuthFile; /**< Filesystem location of a ControlPort
                         *   authentication cookie. */
  char *ExtORPortCookieAuthFile; /**< Filesystem location of Extended
                                 *   ORPort authentication cookie. */
  int CookieAuthFileGroupReadable; /**< Boolean: Is the CookieAuthFile g+r? */
  int ExtORPortCookieAuthFileGroupReadable; /**< Boolean: Is the
                                             * ExtORPortCookieAuthFile g+r? */
  int LeaveStreamsUnattached; /**< Boolean: Does Tor attach new streams to
                          * circuits itself (0), or does it expect a controller
                          * to cope? (1) */
  int DisablePredictedCircuits; /**< Boolean: does Tor preemptively
                                 * make circuits in the background (0),
                                 * or not (1)? */

  /** Process specifier for a controller that ‘owns’ this Tor
   * instance.  Tor will terminate if its owning controller does. */
  char *OwningControllerProcess;
  /** FD specifier for a controller that owns this Tor instance. */
  uint64_t OwningControllerFD;

  int ShutdownWaitLength; /**< When we get a SIGINT and we're a server, how
                           * long do we wait before exiting? */
  char *SafeLogging; /**< Contains "relay", "1", "0" (meaning no scrubbing). */

  /* Derived from SafeLogging */
  enum {
    SAFELOG_SCRUB_ALL, SAFELOG_SCRUB_RELAY, SAFELOG_SCRUB_NONE
  } SafeLogging_;

  int Sandbox; /**< Boolean: should sandboxing be enabled? */
  int SafeSocks; /**< Boolean: should we outright refuse application
                  * connections that use socks4 or socks5-with-local-dns? */
  int ProtocolWarnings; /**< Boolean: when other parties screw up the Tor
                         * protocol, is it a warn or an info in our logs? */
  int TestSocks; /**< Boolean: when we get a socks connection, do we loudly
                  * log whether it was DNS-leaking or not? */
  /** Token Bucket Refill resolution in milliseconds. */
  int TokenBucketRefillInterval;

  /** Boolean: Do we try to enter from a smallish number
   * of fixed nodes? */
  int UseEntryGuards_option;
  /** Internal variable to remember whether we're actually acting on
   * UseEntryGuards_option -- when we're a non-anonymous Single Onion Service,
   * it is always false, otherwise we use the value of UseEntryGuards_option.
   * */
  int UseEntryGuards;

  int NumEntryGuards; /**< How many entry guards do we try to establish? */

  /** If 1, we use any guardfraction information we see in the
   * consensus.  If 0, we don't.  If -1, let the consensus parameter
   * decide. */
  int UseGuardFraction;

  int NumDirectoryGuards; /**< How many dir guards do we try to establish?
                           * If 0, use value from NumEntryGuards. */
  int NumPrimaryGuards; /**< How many primary guards do we want? */

  /** Boolean: Switch to toggle the vanguards-lite subsystem */
  int VanguardsLiteEnabled;

  /** Boolean: Switch to override consensus to enable congestion control */
  int AlwaysCongestionControl;

  /** Boolean: Switch to specify this is an sbws measurement exit */
  int SbwsExit;

  int RephistTrackTime; /**< How many seconds do we keep rephist info? */
  /** Should we always fetch our dir info on the mirror schedule (which
   * means directly from the authorities) no matter our other config? */
  int FetchDirInfoEarly;

  /** Should we fetch our dir info at the start of the consensus period? */
  int FetchDirInfoExtraEarly;

  int DirCache; /**< Cache all directory documents and accept requests via
                 * tunnelled dir conns from clients. If 1, enabled (default);
                 * If 0, disabled. Use dir_server_mode() rather than
                 * referencing this option directly. (Except for routermode
                 * and relay_config, which do direct checks.) */

  char *VirtualAddrNetworkIPv4; /**< Address and mask to hand out for virtual
                                 * MAPADDRESS requests for IPv4 addresses */
  char *VirtualAddrNetworkIPv6; /**< Address and mask to hand out for virtual
                                 * MAPADDRESS requests for IPv6 addresses */
  int ServerDNSSearchDomains; /**< Boolean: If set, we don't force exit
                      * addresses to be FQDNs, but rather search for them in
                      * the local domains. */
  int ServerDNSDetectHijacking; /**< Boolean: If true, check for DNS failure
                                 * hijacking. */
  int ServerDNSRandomizeCase; /**< Boolean: Use the 0x20-hack to prevent
                               * DNS poisoning attacks. */
  char *ServerDNSResolvConfFile; /**< If provided, we configure our internal
                     * resolver from the file here rather than from
                     * /etc/resolv.conf (Unix) or the registry (Windows). */
  char *DirPortFrontPage; /**< This is a full path to a file with an html
                    disclaimer. This allows a server administrator to show
                    that they're running Tor and anyone visiting their server
                    will know this without any specialized knowledge. */
  int DisableDebuggerAttachment; /**< Currently Linux only specific attempt to
                                      disable ptrace; needs BSD testing. */
  /** Boolean: if set, we start even if our resolv.conf file is missing
   * or broken. */
  int ServerDNSAllowBrokenConfig;
  /** Boolean: if set, then even connections to private addresses will get
   * rate-limited. */
  int CountPrivateBandwidth;
  /** A list of addresses that definitely should be resolvable. Used for
   * testing our DNS server. */
  struct smartlist_t *ServerDNSTestAddresses;
  int EnforceDistinctSubnets; /**< If true, don't allow multiple routers in the
                               * same network zone in the same circuit. */
  int AllowNonRFC953Hostnames; /**< If true, we allow connections to hostnames
                                * with weird characters. */
  /** If true, we try resolving hostnames with weird characters. */
  int ServerDNSAllowNonRFC953Hostnames;

  /** If true, we try to download extra-info documents (and we serve them,
   * if we are a cache).  For authorities, this is always true. */
  int DownloadExtraInfo;

  /** If true, we're configured to collect statistics on clients
   * requesting network statuses from us as directory. */
  int DirReqStatistics_option;
  /** Internal variable to remember whether we're actually acting on
   * DirReqStatistics_option -- yes if it's set and we're a server, else no. */
  int DirReqStatistics;

  /** If true, the user wants us to collect statistics on port usage. */
  int ExitPortStatistics;

  /** If true, the user wants us to collect connection statistics. */
  int ConnDirectionStatistics;

  /** If true, the user wants us to collect cell statistics. */
  int CellStatistics;

  /** If true, the user wants us to collect padding statistics. */
  int PaddingStatistics;

  /** If true, the user wants us to collect statistics as entry node. */
  int EntryStatistics;

  /** If true, the user wants us to collect statistics as hidden service
   * directory, introduction point, or rendezvous point. */
  int HiddenServiceStatistics_option;
  /** Internal variable to remember whether we're actually acting on
   * HiddenServiceStatistics_option -- yes if it's set and we're a server,
   * else no. */
  int HiddenServiceStatistics;

  /** If true, include statistics file contents in extra-info documents. */
  int ExtraInfoStatistics;

  /** If true, include overload statistics in extra-info documents. */
  int OverloadStatistics;

  /** If true, do not believe anybody who tells us that a domain resolves
   * to an internal address, or that an internal address has a PTR mapping.
   * Helps avoid some cross-site attacks. */
  int ClientDNSRejectInternalAddresses;

  /** If true, do not accept any requests to connect to internal addresses
   * over randomly chosen exits. */
  int ClientRejectInternalAddresses;

  /** If true, clients may connect over IPv4. If false, they will avoid
   * connecting over IPv4. We enforce this for OR and Dir connections. */
  int ClientUseIPv4;
  /** If true, clients may connect over IPv6. If false, they will avoid
   * connecting over IPv4. We enforce this for OR and Dir connections.
   * Use reachable_addr_use_ipv6() instead of accessing this value
   * directly. */
  int ClientUseIPv6;
  /** If true, prefer an IPv6 OR port over an IPv4 one for entry node
   * connections. If auto, bridge clients prefer IPv6, and other clients
   * prefer IPv4. Use node_ipv6_or_preferred() instead of accessing this value
   * directly. */
  int ClientPreferIPv6ORPort;
  /** If true, prefer an IPv6 directory port over an IPv4 one for direct
   * directory connections. If auto, bridge clients prefer IPv6, and other
   * clients prefer IPv4. Use reachable_addr_prefer_ipv6_dirport() instead of
   * accessing this value directly.  */
  int ClientPreferIPv6DirPort;

  /** If true, always use the compiled hash implementation. If false, always
   * the interpreter. Default of "auto" allows a dynamic fallback from
   * copmiler to interpreter. */
  int CompiledProofOfWorkHash;

  /** If true, the tor client will use conflux for its general purpose
   * circuits which excludes onion service traffic. */
  int ConfluxEnabled;

  /** Has the UX integer value that the client will request from the exit. */
  char *ConfluxClientUX_option;
  int ConfluxClientUX;

  /** The length of time that we think a consensus should be fresh. */
  int V3AuthVotingInterval;
  /** The length of time we think it will take to distribute votes. */
  int V3AuthVoteDelay;
  /** The length of time we think it will take to distribute signatures. */
  int V3AuthDistDelay;
  /** The number of intervals we think a consensus should be valid. */
  int V3AuthNIntervalsValid;

  /** Should advertise and sign consensuses with a legacy key, for key
   * migration purposes? */
  int V3AuthUseLegacyKey;

  /** Location of bandwidth measurement file */
  char *V3BandwidthsFile;

  /** Location of guardfraction file */
  char *GuardfractionFile;

  /** The length of time that we think an initial consensus should be fresh.
   * Only altered on testing networks. */
  int TestingV3AuthInitialVotingInterval;

  /** The length of time we think it will take to distribute initial votes.
   * Only altered on testing networks. */
  int TestingV3AuthInitialVoteDelay;

  /** The length of time we think it will take to distribute initial
   * signatures.  Only altered on testing networks.*/
  int TestingV3AuthInitialDistDelay;

  /** Offset in seconds added to the starting time for consensus
      voting. Only altered on testing networks. */
  int TestingV3AuthVotingStartOffset;

  /** Schedule for when servers should download things in general.  Only
   * altered on testing networks. */
  int TestingServerDownloadInitialDelay;

  /** Schedule for when clients should download things in general.  Only
   * altered on testing networks. */
  int TestingClientDownloadInitialDelay;

  /** Schedule for when servers should download consensuses.  Only altered
   * on testing networks. */
  int TestingServerConsensusDownloadInitialDelay;

  /** Schedule for when clients should download consensuses.  Only altered
   * on testing networks. */
  int TestingClientConsensusDownloadInitialDelay;

  /** Schedule for when clients should download consensuses from authorities
   * if they are bootstrapping (that is, they don't have a usable, reasonably
   * live consensus).  Only used by clients fetching from a list of fallback
   * directory mirrors.
   *
   * This schedule is incremented by (potentially concurrent) connection
   * attempts, unlike other schedules, which are incremented by connection
   * failures.  Only altered on testing networks. */
  int ClientBootstrapConsensusAuthorityDownloadInitialDelay;

  /** Schedule for when clients should download consensuses from fallback
   * directory mirrors if they are bootstrapping (that is, they don't have a
   * usable, reasonably live consensus). Only used by clients fetching from a
   * list of fallback directory mirrors.
   *
   * This schedule is incremented by (potentially concurrent) connection
   * attempts, unlike other schedules, which are incremented by connection
   * failures.  Only altered on testing networks. */
  int ClientBootstrapConsensusFallbackDownloadInitialDelay;

  /** Schedule for when clients should download consensuses from authorities
   * if they are bootstrapping (that is, they don't have a usable, reasonably
   * live consensus).  Only used by clients which don't have or won't fetch
   * from a list of fallback directory mirrors.
   *
   * This schedule is incremented by (potentially concurrent) connection
   * attempts, unlike other schedules, which are incremented by connection
   * failures.  Only altered on testing networks. */
  int ClientBootstrapConsensusAuthorityOnlyDownloadInitialDelay;

  /** Schedule for when clients should download bridge descriptors.  Only
   * altered on testing networks. */
  int TestingBridgeDownloadInitialDelay;

  /** Schedule for when clients should download bridge descriptors when they
   * have no running bridges.  Only altered on testing networks. */
  int TestingBridgeBootstrapDownloadInitialDelay;

  /** When directory clients have only a few descriptors to request, they
   * batch them until they have more, or until this amount of time has
   * passed.  Only altered on testing networks. */
  int TestingClientMaxIntervalWithoutRequest;

  /** How long do we let a directory connection stall before expiring
   * it?  Only altered on testing networks. */
  int TestingDirConnectionMaxStall;

  /** How many simultaneous in-progress connections will we make when trying
   * to fetch a consensus before we wait for one to complete, timeout, or
   * error out?  Only altered on testing networks. */
  int ClientBootstrapConsensusMaxInProgressTries;

  /** If true, we take part in a testing network. Change the defaults of a
   * couple of other configuration options and allow to change the values
   * of certain configuration options. */
  int TestingTorNetwork;

  /** Enable CONN_BW events.  Only altered on testing networks. */
  int TestingEnableConnBwEvent;

  /** Enable CELL_STATS events.  Only altered on testing networks. */
  int TestingEnableCellStatsEvent;

  /** If true, and we have GeoIP data, and we're a bridge, keep a per-country
   * count of how many client addresses have contacted us so that we can help
   * the bridge authority guess which countries have blocked access to us. */
  int BridgeRecordUsageByCountry;

  /** Optionally, IPv4 and IPv6 GeoIP data. */
  char *GeoIPFile;
  char *GeoIPv6File;

  /** Autobool: if auto, then any attempt to Exclude{Exit,}Nodes a particular
   * country code will exclude all nodes in ?? and A1.  If true, all nodes in
   * ?? and A1 are excluded. Has no effect if we don't know any GeoIP data. */
  int GeoIPExcludeUnknown;

  /** If true, SIGHUP should reload the torrc.  Sometimes controllers want
   * to make this false. */
  int ReloadTorrcOnSIGHUP;

  /** The main parameter for picking circuits within a connection.
   *
   * If this value is positive, when picking a cell to relay on a connection,
   * we always relay from the circuit whose weighted cell count is lowest.
   * Cells are weighted exponentially such that if one cell is sent
   * 'CircuitPriorityHalflife' seconds before another, it counts for half as
   * much.
   *
   * If this value is zero, we're disabling the cell-EWMA algorithm.
   *
   * If this value is negative, we're using the default approach
   * according to either Tor or a parameter set in the consensus.
   */
  double CircuitPriorityHalflife;

  /** Set to true if the TestingTorNetwork configuration option is set.
   * This is used so that options_validate() has a chance to realize that
   * the defaults have changed. */
  int UsingTestNetworkDefaults_;

  /** If 1, we try to use microdescriptors to build circuits.  If 0, we don't.
   * If -1, Tor decides. */
  int UseMicrodescriptors;

  /** File where we should write the ControlPort. */
  char *ControlPortWriteToFile;
  /** Should that file be group-readable? */
  int ControlPortFileGroupReadable;

#define MAX_MAX_CLIENT_CIRCUITS_PENDING 1024
  /** Maximum number of non-open general-purpose origin circuits to allow at
   * once. */
  int MaxClientCircuitsPending;

  /** If 1, we accept and launch no external network connections, except on
   * control ports. */
  int DisableNetwork;

  /**
   * Parameters for path-bias detection.
   * @{
   * These options override the default behavior of Tor's (**currently
   * experimental**) path bias detection algorithm. To try to find broken or
   * misbehaving guard nodes, Tor looks for nodes where more than a certain
   * fraction of circuits through that guard fail to get built.
   *
   * The PathBiasCircThreshold option controls how many circuits we need to
   * build through a guard before we make these checks.  The
   * PathBiasNoticeRate, PathBiasWarnRate and PathBiasExtremeRate options
   * control what fraction of circuits must succeed through a guard so we
   * won't write log messages.  If less than PathBiasExtremeRate circuits
   * succeed *and* PathBiasDropGuards is set to 1, we disable use of that
   * guard.
   *
   * When we have seen more than PathBiasScaleThreshold circuits through a
   * guard, we scale our observations by 0.5 (governed by the consensus) so
   * that new observations don't get swamped by old ones.
   *
   * By default, or if a negative value is provided for one of these options,
   * Tor uses reasonable defaults from the networkstatus consensus document.
   * If no defaults are available there, these options default to 150, .70,
   * .50, .30, 0, and 300 respectively.
   */
  int PathBiasCircThreshold;
  double PathBiasNoticeRate;
  double PathBiasWarnRate;
  double PathBiasExtremeRate;
  int PathBiasDropGuards;
  int PathBiasScaleThreshold;
  /** @} */

  /**
   * Parameters for path-bias use detection
   * @{
   * Similar to the above options, these options override the default behavior
   * of Tor's (**currently experimental**) path use bias detection algorithm.
   *
   * Where as the path bias parameters govern thresholds for successfully
   * building circuits, these four path use bias parameters govern thresholds
   * only for circuit usage. Circuits which receive no stream usage are not
   * counted by this detection algorithm. A used circuit is considered
   * successful if it is capable of carrying streams or otherwise receiving
   * well-formed responses to RELAY cells.
   *
   * By default, or if a negative value is provided for one of these options,
   * Tor uses reasonable defaults from the networkstatus consensus document.
   * If no defaults are available there, these options default to 20, .80,
   * .60, and 100, respectively.
   */
  int PathBiasUseThreshold;
  double PathBiasNoticeUseRate;
  double PathBiasExtremeUseRate;
  int PathBiasScaleUseThreshold;
  /** @} */

  int IPv6Exit; /**< Do we support exiting to IPv6 addresses? */

  /** Fraction: */
  double PathsNeededToBuildCircuits;

  /** What expiry time shall we place on our SSL certs? "0" means we
   * should guess a suitable value. */
  int SSLKeyLifetime;

  /** How long (seconds) do we keep a guard before picking a new one? */
  int GuardLifetime;

  /** Is this an exit node?  This is a tristate, where "1" means "yes, and use
   * the default exit policy if none is given" and "0" means "no; exit policy
   * is 'reject *'" and "auto" (-1) means "same as 1, but warn the user."
   *
   * XXXX Eventually, the default will be 0. */
  int ExitRelay;

  /** For how long (seconds) do we declare our signing keys to be valid? */
  int SigningKeyLifetime;
  /** For how long (seconds) do we declare our link keys to be valid? */
  int TestingLinkCertLifetime;
  /** For how long (seconds) do we declare our auth keys to be valid? */
  int TestingAuthKeyLifetime;

  /** How long before signing keys expire will we try to make a new one? */
  int TestingSigningKeySlop;
  /** How long before link keys expire will we try to make a new one? */
  int TestingLinkKeySlop;
  /** How long before auth keys expire will we try to make a new one? */
  int TestingAuthKeySlop;

  /** Force use of offline master key features: never generate a master
   * ed25519 identity key except from tor --keygen */
  int OfflineMasterKey;

  key_expiration_format_t key_expiration_format;

  enum {
    FORCE_PASSPHRASE_AUTO=0,
    FORCE_PASSPHRASE_ON,
    FORCE_PASSPHRASE_OFF
  } keygen_force_passphrase;
  int use_keygen_passphrase_fd;
  int keygen_passphrase_fd;
  int change_key_passphrase;
  char *master_key_fname;

  /** Autobool: Do we try to retain capabilities if we can? */
  int KeepBindCapabilities;

  /** Maximum total size of unparseable descriptors to log during the
   * lifetime of this Tor process.
   */
  uint64_t MaxUnparseableDescSizeToLog;

  /** If 1, we skip all OOS checks. */
  int DisableOOSCheck;

  /** Autobool: Should we include Ed25519 identities in extend2 cells?
   * If -1, we should do whatever the consensus parameter says. */
  int ExtendByEd25519ID;

  /** Bool (default: 0): Tells if a %include was used on torrc */
  int IncludeUsed;

  /** The seconds after expiration which we as a relay should keep old
   * consensuses around so that we can generate diffs from them.  If 0,
   * use the default. */
  int MaxConsensusAgeForDiffs;

  /** Bool (default: 0). Tells Tor to never try to exec another program.
   */
  int NoExec;

  /** Have the KIST scheduler run every X milliseconds. If less than zero, do
   * not use the KIST scheduler but use the old vanilla scheduler instead. If
   * zero, do what the consensus says and fall back to using KIST as if this is
   * set to "10 msec" if the consensus doesn't say anything. */
  int KISTSchedRunInterval;

  /** A multiplier for the KIST per-socket limit calculation. */
  double KISTSockBufSizeFactor;

  /** The list of scheduler type string ordered by priority that is first one
   * has to be tried first. Default: KIST,KISTLite,Vanilla */
  struct smartlist_t *Schedulers;
  /** An ordered list of scheduler_types mapped from Schedulers. */
  struct smartlist_t *SchedulerTypes_;

  /** List of files that were opened by %include in torrc and torrc-defaults */
  struct smartlist_t *FilesOpenedByIncludes;

  /** If true, Tor shouldn't install any posix signal handlers, since it is
   * running embedded inside another process.
   */
  int DisableSignalHandlers;

  /** Interval: how long without activity does it take for a client
   * to become dormant?
   **/
  int DormantClientTimeout;

  /**
   * Boolean: If enabled, then we consider the timeout when deciding whether
   * to be dormant.  If not enabled, then only the SIGNAL ACTIVE/DORMANT
   * controls can change our status.
   **/
  int DormantTimeoutEnabled;

  /** Boolean: true if having an idle stream is sufficient to prevent a client
   * from becoming dormant.
   **/
  int DormantTimeoutDisabledByIdleStreams;

  /** Boolean: true if Tor should be dormant the first time it starts with
   * a datadirectory; false otherwise. */
  int DormantOnFirstStartup;
  /**
   * Boolean: true if Tor should treat every startup event as cancelling
   * a possible previous dormant state.
   **/
  int DormantCanceledByStartup;

  /** List of policy allowed to query the Metrics port. */
  struct config_line_t *MetricsPortPolicy;

  /** How far must we be into the current bandwidth-measurement period to
   * report bandwidth observations from this period? */
  int TestingMinTimeToReportBandwidth;

  /**
   * Configuration objects for individual modules.
   *
   * Never access this field or its members directly: instead, use the module
   * in question to get its relevant configuration object.
   */
  struct config_suite_t *subconfigs_;
};

#endif /* !defined(TOR_OR_OPTIONS_ST_H) */
