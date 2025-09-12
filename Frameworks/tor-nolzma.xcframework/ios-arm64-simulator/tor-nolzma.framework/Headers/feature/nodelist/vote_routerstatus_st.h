/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file vote_routerstatus_st.h
 * @brief Routerstatus (vote entry) structure
 **/
#ifndef VOTE_ROUTERSTATUS_ST_H
#define VOTE_ROUTERSTATUS_ST_H

#include "feature/nodelist/routerstatus_st.h"
#include "lib/defs/x25519_sizes.h"

/** The claim about a single router, made in a vote. */
struct vote_routerstatus_t {
  routerstatus_t status; /**< Underlying 'status' object for this router.
                          * Flags are redundant. */
  time_t published_on; /**< When was this router published? */
  /** How many known-flags are allowed in a vote? This is the width of
   * the flags field of vote_routerstatus_t */
#define MAX_KNOWN_FLAGS_IN_VOTE 64
  uint64_t flags; /**< Bit-field for all recognized flags; index into
                   * networkstatus_t.known_flags. */
  char *version; /**< The version that the authority says this router is
                  * running. */
  char *protocols; /**< The protocols that this authority says this router
                    * provides. */
  unsigned int has_measured_bw:1; /**< The vote had a measured bw */
  /** True iff the vote included an entry for ed25519 ID, or included
   * "id ed25519 none" to indicate that there was no ed25519 ID. */
  unsigned int has_ed25519_listing:1;
  /** True if the Ed25519 listing here is the consensus-opinion for the
   * Ed25519 listing; false if there was no consensus on Ed25519 key status,
   * or if this VRS doesn't reflect it. */
  unsigned int ed25519_reflects_consensus:1;
  uint32_t measured_bw_kb; /**< Measured bandwidth (capacity) of the router */
  /** The hash or hashes that the authority claims this microdesc has. */
  vote_microdesc_hash_t *microdesc;
  /** Ed25519 identity for this router, or zero if it has none. */
  uint8_t ed25519_id[ED25519_PUBKEY_LEN];
};

#endif /* !defined(VOTE_ROUTERSTATUS_ST_H) */
