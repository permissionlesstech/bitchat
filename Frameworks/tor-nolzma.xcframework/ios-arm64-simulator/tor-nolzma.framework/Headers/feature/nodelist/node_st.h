/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file node_st.h
 * @brief Node information structure.
 **/

#ifndef NODE_ST_H
#define NODE_ST_H

#include "feature/hs/hsdir_index_st.h"
#include "lib/crypt_ops/crypto_ed25519.h"
#include "ext/ht.h"

/** A node_t represents a Tor router.
 *
 * Specifically, a node_t is a Tor router as we are using it: a router that
 * we are considering for circuits, connections, and so on.  A node_t is a
 * thin wrapper around the routerstatus, routerinfo, and microdesc for a
 * single router, and provides a consistent interface for all of them.
 *
 * Also, a node_t has mutable state.  While a routerinfo, a routerstatus,
 * and a microdesc have[*] only the information read from a router
 * descriptor, a consensus entry, and a microdescriptor (respectively)...
 * a node_t has flags based on *our own current opinion* of the node.
 *
 * [*] Actually, there is some leftover information in each that is mutable.
 *  We should try to excise that.
 */
struct node_t {
  /* Indexing information */

  /** Used to look up the node_t by its identity digest. */
  HT_ENTRY(node_t) ht_ent;
  /** Used to look up the node_t by its ed25519 identity digest. */
  HT_ENTRY(node_t) ed_ht_ent;
  /** Position of the node within the list of nodes */
  int nodelist_idx;

  /** The identity digest of this node_t.  No more than one node_t per
   * identity may exist at a time. */
  char identity[DIGEST_LEN];

  /** The ed25519 identity of this node_t. This field is nonzero iff we
   * currently have an ed25519 identity for this node in either md or ri,
   * _and_ this node has been inserted to the ed25519-to-node map in the
   * nodelist.
   */
  ed25519_public_key_t ed25519_id;

  microdesc_t *md;
  routerinfo_t *ri;
  routerstatus_t *rs;

  /* local info: copied from routerstatus, then possibly frobbed based
   * on experience.  Authorities set this stuff directly.  Note that
   * these reflect knowledge of the primary (IPv4) OR port only.  */

  unsigned int is_running:1; /**< As far as we know, is this OR currently
                              * running? */
  unsigned int is_valid:1; /**< Has a trusted dirserver validated this OR?
                            *  (For Authdir: Have we validated this OR?) */
  unsigned int is_fast:1; /** Do we think this is a fast OR? */
  unsigned int is_stable:1; /** Do we think this is a stable OR? */
  unsigned int is_possible_guard:1; /**< Do we think this is an OK guard? */
  unsigned int is_exit:1; /**< Do we think this is an OK exit? */
  unsigned int is_bad_exit:1; /**< Do we think this exit is censored, borked,
                               * or otherwise nasty? */
  /** Is this unsuitable for use as anything besides a middle relay? */
  unsigned int is_middle_only:1;
  unsigned int is_hs_dir:1; /**< True iff this router is a hidden service
                             * directory according to the authorities. */
  unsigned int strip_guard:1; /**< True iff we should strip the Guard flag. */
  unsigned int strip_hsdir:1; /**< True iff we should strip the HSDir flag. */
  unsigned int strip_v2dir:1; /**< True iff we should strip the V2Dir flag. */

  /* Local info: warning state. */

  unsigned int name_lookup_warned:1; /**< Have we warned the user for referring
                                      * to this (unnamed) router by nickname?
                                      */

  /** Local info: we treat this node as if it rejects everything */
  unsigned int rejects_all:1;

  /* Local info: derived. */

  /** True if the IPv6 OR port is preferred over the IPv4 OR port. */
  unsigned int ipv6_preferred:1;

  /** According to the geoip db what country is this router in? */
  /* IPv6: what is this supposed to mean with multiple OR ports? */
  country_t country;

  /* The below items are used only by authdirservers for
   * reachability testing. */

  /** When was the last time we could reach this OR? */
  time_t last_reachable;        /* IPv4. */
  time_t last_reachable6;       /* IPv6. */

  /* Hidden service directory index data. This is used by a service or client
   * in order to know what's the hs directory index for this node at the time
   * the consensus is set. */
  struct hsdir_index_t hsdir_index;
};

#endif /* !defined(NODE_ST_H) */
