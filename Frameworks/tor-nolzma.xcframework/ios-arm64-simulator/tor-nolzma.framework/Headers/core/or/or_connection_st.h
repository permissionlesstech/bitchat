/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file or_connection_st.h
 * @brief OR connection structure.
 **/

#ifndef OR_CONNECTION_ST_H
#define OR_CONNECTION_ST_H

#include "core/or/connection_st.h"
#include "lib/evloop/token_bucket.h"

struct tor_tls_t;

/** Subtype of connection_t for an "OR connection" -- that is, one that speaks
 * cells over TLS. */
struct or_connection_t {
  connection_t base_;

  /** Hash of the public RSA key for the other side's identity key, or zeroes
   * if the other side hasn't shown us a valid identity key. */
  char identity_digest[DIGEST_LEN];

  /** This is the ClientHash value we expect to receive from the
   *  client during the Extended ORPort authentication protocol. We
   *  compute it upon receiving the ClientNonce from the client, and we
   *  compare it with the actual ClientHash value sent by the
   *  client. */
  char *ext_or_auth_correct_client_hash;
  /** String carrying the name of the pluggable transport
   *  (e.g. "obfs2") that is obfuscating this connection. If no
   *  pluggable transports are used, it's NULL. */
  char *ext_or_transport;

  char *nickname; /**< Nickname of OR on other side (if any). */

  struct tor_tls_t *tls; /**< TLS connection state. */
  int tls_error; /**< Last tor_tls error code. */
  /** When we last used this conn for any client traffic. If not
   * recent, we can rate limit it further. */

  /* Channel using this connection */
  channel_tls_t *chan;

  /**
   * The "canonical" address and port for this relay's ORPort, if this is
   * a known relay.
   *
   * An ORPort is "canonical" in this sense only if it is the same ORPort
   * that is listed for this identity in the consensus we have.
   *
   * This field may be set on outbound connections for _any_ relay, and on
   * inbound connections after authentication.  If we don't know the relay's
   * identity, or if we don't have the relay's identity in our consensus, we
   * leave this address as UNSPEC.
   **/
  tor_addr_port_t canonical_orport;

  /** Should this connection be used for extending circuits to the server
   * matching the <b>identity_digest</b> field?  Set to true if we're pretty
   * sure we aren't getting MITMed, either because we're connected to an
   * address listed in a server descriptor, or because an authenticated
   * NETINFO cell listed the address we're connected to as recognized. */
  unsigned int is_canonical:1;

  /** True iff this is an outgoing connection. */
  unsigned int is_outgoing:1;
  unsigned int proxy_type:3; /**< One of PROXY_NONE...PROXY_HAPROXY */
  unsigned int wide_circ_ids:1;
  /** True iff a failure on this connection indicates a possible
   * bootstrapping problem.  We set this as true if we notice that this
   * connection could handle a pending origin circuit, or if we launch it to
   * handle an origin circuit. */
  unsigned int potentially_used_for_bootstrapping:1;
  /** True iff this connection has had its bootstrap failure logged with
   * control_event_bootstrap_problem. */
  unsigned int have_noted_bootstrap_problem:1;
  /** True iff this is a client connection and its address has been put in the
   * geoip cache and handled by the DoS mitigation subsystem. We use this to
   * insure we have a coherent count of concurrent connection. */
  unsigned int tracked_for_dos_mitigation : 1;
  /** True iff this connection is using a pluggable transport */
  unsigned int is_pt : 1;

  uint16_t link_proto; /**< What protocol version are we using? 0 for
                        * "none negotiated yet." */
  uint16_t idle_timeout; /**< How long can this connection sit with no
                          * circuits on it before we close it? Based on
                          * IDLE_CIRCUIT_TIMEOUT_{NON,}CANONICAL and
                          * on is_canonical, randomized. */
  or_handshake_state_t *handshake_state; /**< If we are setting this connection
                                          * up, state information to do so. */

  time_t timestamp_lastempty; /**< When was the outbuf last completely empty?*/

  token_bucket_rw_t bucket; /**< Used for rate limiting when the connection is
                          * in state CONN_OPEN. */

  /*
   * Count the number of bytes flushed out on this orconn, and the number of
   * bytes TLS actually sent - used for overhead estimation for scheduling.
   */
  uint64_t bytes_xmitted, bytes_xmitted_by_tls;
};

#endif /* !defined(OR_CONNECTION_ST_H) */
