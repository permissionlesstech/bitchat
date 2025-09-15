/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file edge_connection_st.h
 * @brief Edge-connection structure.
 **/

#ifndef EDGE_CONNECTION_ST_H
#define EDGE_CONNECTION_ST_H

#include "core/or/or.h"

#include "core/or/connection_st.h"
#include "lib/evloop/token_bucket.h"

/** Subtype of connection_t for an "edge connection" -- that is, an entry (ap)
 * connection, or an exit. */
struct edge_connection_t {
  connection_t base_;

  struct edge_connection_t *next_stream; /**< Points to the next stream at this
                                          * edge, if any */
  int package_window; /**< How many more relay cells can I send into the
                       * circuit? */
  int deliver_window; /**< How many more relay cells can end at me? */

  /** The circuit (if any) that this edge connection is using.
   * Note that edges that use conflux should use the helpers
   * in conflux_util.c instead of accessing this directly. */
  struct circuit_t *on_circuit;

  /** A pointer to which node in the circ this conn exits at.  Set for AP
   * connections and for hidden service exit connections.
   * Note that edges that use conflux should use the helpers
   * in conflux_util.c instead of accessing this directly. */
  struct crypt_path_t *cpath_layer;

  /* Hidden service connection identifier for edge connections. Used by the HS
   * client-side code to identify client SOCKS connections and by the
   * service-side code to match HS circuits with their streams. */
  struct hs_ident_edge_conn_t *hs_ident;

  uint32_t address_ttl; /**< TTL for address-to-addr mapping on exit
                         * connection.  Exit connections only. */
  uint32_t begincell_flags; /** Flags sent or received in the BEGIN cell
                             * for this connection */

  streamid_t stream_id; /**< The stream ID used for this edge connection on its
                         * circuit */

  /** The reason why this connection is closing; passed to the controller. */
  uint16_t end_reason;

  /** Bytes read since last call to control_event_stream_bandwidth_used() */
  uint32_t n_read;

  /** Bytes written since last call to control_event_stream_bandwidth_used() */
  uint32_t n_written;

  /** True iff this connection is for a DNS request only. */
  unsigned int is_dns_request:1;
  /** True iff this connection is for a PTR DNS request. (exit only) */
  unsigned int is_reverse_dns_lookup:1;

  unsigned int edge_has_sent_end:1; /**< For debugging; only used on edge
                         * connections.  Set once we've set the stream end,
                         * and check in connection_about_to_close_connection().
                         */

  /** Unique ID for directory requests; this used to be in connection_t, but
   * that's going away and being used on channels instead.  We still tag
   * edge connections with dirreq_id from circuits, so it's copied here. */
  uint64_t dirreq_id;

  /* The following are flow control fields */

  /** Used for rate limiting the read side of this edge connection when
   * congestion control is enabled on its circuit. The XON cell ewma_drain_rate
   * parameter is used to set the bucket limits. */
  token_bucket_rw_t bucket;

  /**
   * Monotime timestamp of the last time we sent a flow control message
   * for this edge, used to compute advisory rates */
  uint64_t drain_start_usec;

  /**
   * Number of bytes written since we either emptied our buffers,
   * or sent an advisory drate rate. Can wrap, buf if so,
   * we must reset the usec timestamp above. (Or make this u64, idk).
   */
  uint32_t drained_bytes;
  uint32_t prev_drained_bytes;

  /**
   * N_EWMA of the drain rate of writes on this edge conn
   * while buffers were present.
   */
  uint32_t ewma_drain_rate;

  /**
   * The ewma drain rate the last time we sent an xon.
   */
  uint32_t ewma_rate_last_sent;

  /**
   * The following fields are used to count the total bytes sent on this
   * stream, and compare them to the number of XON and XOFFs received, so
   * that clients can check rate limits of XOFF/XON to prevent dropmark
   * attacks. */
  uint32_t total_bytes_xmit;

  /** Number of XOFFs received */
  uint8_t num_xoff_recv;

  /** Number of XONs received */
  uint8_t num_xon_recv;

  /**
   * Flag that tells us if an XOFF has been sent; cleared when we send an XON.
   * Used to avoid sending multiple */
  uint8_t xoff_sent : 1;

  /** Flag that tells us if an XOFF has been received; cleared when we get
   * an XON. Used to ensure that this edge keeps reads on its edge socket
   * disabled. */
  uint8_t xoff_received : 1;
};

#endif /* !defined(EDGE_CONNECTION_ST_H) */
