/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dir_connection_st.h
 * @brief Client/server directory connection structure.
 **/

#ifndef DIR_CONNECTION_ST_H
#define DIR_CONNECTION_ST_H

#include "core/or/connection_st.h"

struct tor_compress_state_t;

/** Subtype of connection_t for an "directory connection" -- that is, an HTTP
 * connection to retrieve or serve directory material. */
struct dir_connection_t {
  connection_t base_;

 /** Which 'resource' did we ask the directory for? This is typically the part
  * of the URL string that defines, relative to the directory conn purpose,
  * what thing we want.  For example, in router descriptor downloads by
  * descriptor digest, it contains "d/", then one or more +-separated
  * fingerprints.
  **/
  char *requested_resource;
  /** Is this dirconn direct, or via a multi-hop Tor circuit?
   * Direct connections can use the DirPort, or BEGINDIR over the ORPort. */
  unsigned int dirconn_direct:1;

  /** If we're fetching descriptors, what router purpose shall we assign
   * to them? */
  uint8_t router_purpose;

  /** List of spooled_resource_t for objects that we're spooling. We use
   * it from back to front. */
  smartlist_t *spool;
  /** The compression object doing on-the-fly compression for spooled data. */
  struct tor_compress_state_t *compress_state;

  /* Hidden service connection identifier for dir connections: Used by HS
     client-side code to fetch HS descriptors, and by the service-side code to
     upload descriptors. Also used by the HSDir, setting only the blinded key,
     in order to locate back the descriptor in the cache once the dir stream is
     closed. */
  struct hs_ident_dir_conn_t *hs_ident;

  /** If this is a one-hop connection, tracks the state of the directory guard
   * for this connection (if any). */
  struct circuit_guard_state_t *guard_state;

  char identity_digest[DIGEST_LEN]; /**< Hash of the public RSA key for
                                     * the directory server's signing key. */

  /** Unique ID for directory requests; this used to be in connection_t, but
   * that's going away and being used on channels instead.  The dirserver still
   * needs this for the incoming side, so it's moved here. */
  uint64_t dirreq_id;

#ifdef MEASUREMENTS_21206
  /** Number of RELAY_DATA cells received. */
  uint32_t data_cells_received;

  /** Number of RELAY_DATA cells sent. */
  uint32_t data_cells_sent;
#endif /* defined(MEASUREMENTS_21206) */
};

#endif /* !defined(DIR_CONNECTION_ST_H) */
