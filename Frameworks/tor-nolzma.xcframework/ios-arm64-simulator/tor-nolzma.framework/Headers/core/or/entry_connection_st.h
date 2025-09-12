/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file entry_connection_st.h
 * @brief Entry connection structure.
 **/

#ifndef ENTRY_CONNECTION_ST_H
#define ENTRY_CONNECTION_ST_H

#include "core/or/edge_connection_st.h"

/** Subtype of edge_connection_t for an "entry connection" -- that is, a SOCKS
 * connection, a DNS request, a TransPort connection or a NATD connection */
struct entry_connection_t {
  struct edge_connection_t edge_;

  /** Nickname of planned exit node -- used with .exit support. */
  /* XXX prop220: we need to make chosen_exit_name able to encode Ed IDs too.
   * That's logically part of the UI parts for prop220 though. */
  char *chosen_exit_name;

  socks_request_t *socks_request; /**< SOCKS structure describing request (AP
                                   * only.) */

  /* === Isolation related, AP only. === */
  entry_port_cfg_t entry_cfg;
  /** AP only: The newnym epoch in which we created this connection. */
  unsigned nym_epoch;

  /** AP only: The original requested address before we rewrote it. */
  char *original_dest_address;
  /* Other fields to isolate on already exist.  The ClientAddr is addr.  The
     ClientProtocol is a combination of type and socks_request->
     socks_version.  SocksAuth is socks_request->username/password.
     DestAddr is in socks_request->address. */

  /** Number of times we've reassigned this application connection to
   * a new circuit. We keep track because the timeout is longer if we've
   * already retried several times. */
  uint8_t num_socks_retries;

  /** For AP connections only: buffer for data that we have sent
   * optimistically, which we might need to re-send if we have to
   * retry this connection. */
  struct buf_t *pending_optimistic_data;
  /* For AP connections only: buffer for data that we previously sent
  * optimistically which we are currently re-sending as we retry this
  * connection. */
  struct buf_t *sending_optimistic_data;

  /** If this is a DNSPort connection, this field holds the pending DNS
   * request that we're going to try to answer.  */
  struct evdns_server_request *dns_server_request;

#define DEBUGGING_17659

#ifdef DEBUGGING_17659
  uint16_t marked_pending_circ_line;
  const char *marked_pending_circ_file;
#endif

#define NUM_CIRCUITS_LAUNCHED_THRESHOLD 10
  /** Number of times we've launched a circuit to handle this stream. If
    * it gets too high, that could indicate an inconsistency between our
    * "launch a circuit to handle this stream" logic and our "attach our
    * stream to one of the available circuits" logic. */
  unsigned int num_circuits_launched:4;

  /** True iff this stream must attach to a one-hop circuit (e.g. for
   * begin_dir). */
  unsigned int want_onehop:1;
  /** True iff this stream should use a BEGIN_DIR relay command to establish
   * itself rather than BEGIN (either via onehop or via a whole circuit). */
  unsigned int use_begindir:1;

  /** For AP connections only. If 1, and we fail to reach the chosen exit,
   * stop requiring it. */
  unsigned int chosen_exit_optional:1;
  /** For AP connections only. If non-zero, this exit node was picked as
   * a result of the TrackHostExit, and the value decrements every time
   * we fail to complete a circuit to our chosen exit -- if it reaches
   * zero, abandon the associated mapaddress. */
  unsigned int chosen_exit_retries:3;

  /** True iff this is an AP connection that came from a transparent or
   * NATd connection */
  unsigned int is_transparent_ap:1;

  /** For AP connections only: Set if this connection's target exit node
   * allows optimistic data (that is, data sent on this stream before
   * the exit has sent a CONNECTED cell) and we have chosen to use it.
   */
  unsigned int may_use_optimistic_data : 1;

  /** True iff this is a connection to a HS that has PoW defenses enabled,
   * so we know not to apply the usual SOCKS timeout. */
  unsigned int hs_with_pow_conn : 1;
};

/** Cast a entry_connection_t subtype pointer to a edge_connection_t **/
#define ENTRY_TO_EDGE_CONN(c) (&(((c))->edge_))

#endif /* !defined(ENTRY_CONNECTION_ST_H) */
