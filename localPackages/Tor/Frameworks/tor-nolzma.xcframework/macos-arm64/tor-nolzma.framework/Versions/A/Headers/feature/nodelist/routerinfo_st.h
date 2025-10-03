/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file routerinfo_st.h
 * @brief Router descriptor structure.
 **/

#ifndef ROUTERINFO_ST_H
#define ROUTERINFO_ST_H

#include "feature/nodelist/signed_descriptor_st.h"

struct curve25519_public_key_t;

/** Information about another onion router in the network. */
struct routerinfo_t {
  signed_descriptor_t cache_info;
  char *nickname; /**< Human-readable OR name. */

  /** A router's IPv4 address. */
  tor_addr_t ipv4_addr;
  uint16_t ipv4_orport;
  uint16_t ipv4_dirport;

  /** A router's IPv6 address, if it has one. */
  tor_addr_t ipv6_addr;
  uint16_t ipv6_orport;

  /**
   * Public RSA TAP key for onions, ASN.1 encoded.  We store this
   * in its encoded format since storing it as a crypto_pk_t uses
   * significantly more memory. */
  char *onion_pkey;
  /** Length of onion_pkey, in bytes. */
  size_t onion_pkey_len;

  crypto_pk_t *identity_pkey;  /**< Public RSA key for signing. */
  /** Public curve25519 key for onions */
  struct curve25519_public_key_t *onion_curve25519_pkey;
  /** What's the earliest expiration time on all the certs in this
   * routerinfo? */
  time_t cert_expiration_time;

  char *platform; /**< What software/operating system is this OR using? */

  char *protocol_list; /**< Encoded list of subprotocol versions supported
                        * by this OR */

  /* link info */
  uint32_t bandwidthrate; /**< How many bytes does this OR add to its token
                           * bucket per second? */
  uint32_t bandwidthburst; /**< How large is this OR's token bucket? */
  /** How many bytes/s is this router known to handle? */
  uint32_t bandwidthcapacity;
  smartlist_t *exit_policy; /**< What streams will this OR permit
                             * to exit on IPv4?  NULL for 'reject *:*'. */
  /** What streams will this OR permit to exit on IPv6?
   * NULL for 'reject *:*' */
  struct short_policy_t *ipv6_exit_policy;
  long uptime; /**< How many seconds the router claims to have been up */
  smartlist_t *declared_family; /**< Nicknames of router which this router
                                 * claims are its family. */
  char *contact_info; /**< Declared contact info for this router. */
  unsigned int is_hibernating:1; /**< Whether the router claims to be
                                  * hibernating */
  unsigned int caches_extra_info:1; /**< Whether the router says it caches and
                                     * serves extrainfo documents. */
  unsigned int allow_single_hop_exits:1;  /**< Whether the router says
                                           * it allows single hop exits. */

  unsigned int wants_to_be_hs_dir:1; /**< True iff this router claims to be
                                      * a hidden service directory. */
  unsigned int policy_is_reject_star:1; /**< True iff the exit policy for this
                                         * router rejects everything. */
  /** True if, after we have added this router, we should re-launch
   * tests for it. */
  unsigned int needs_retest_if_added:1;

  /** True iff this router included "tunnelled-dir-server" in its descriptor,
   * implying it accepts tunnelled directory requests, or it advertised
   * dir_port > 0. */
  unsigned int supports_tunnelled_dir_requests:1;

  /** Used during voting to indicate that we should not include an entry for
   * this routerinfo. Used only during voting. */
  unsigned int omit_from_vote:1;

  /** Flags to summarize the protocol versions for this routerinfo_t. */
  protover_summary_flags_t pv;

/** Tor can use this router for general positions in circuits; we got it
 * from a directory server as usual, or we're an authority and a server
 * uploaded it. */
#define ROUTER_PURPOSE_GENERAL 0
/** Tor should avoid using this router for circuit-building: we got it
 * from a controller.  If the controller wants to use it, it'll have to
 * ask for it by identity. */
#define ROUTER_PURPOSE_CONTROLLER 1
/** Tor should use this router only for bridge positions in circuits: we got
 * it via a directory request from the bridge itself, or a bridge
 * authority. */
#define ROUTER_PURPOSE_BRIDGE 2
/** Tor should not use this router; it was marked in cached-descriptors with
 * a purpose we didn't recognize. */
#define ROUTER_PURPOSE_UNKNOWN 255

  /** In what way did we find out about this router?  One of ROUTER_PURPOSE_*.
   * Routers of different purposes are kept segregated and used for different
   * things; see notes on ROUTER_PURPOSE_* macros above.
   */
  uint8_t purpose;
};

#endif /* !defined(ROUTERINFO_ST_H) */
