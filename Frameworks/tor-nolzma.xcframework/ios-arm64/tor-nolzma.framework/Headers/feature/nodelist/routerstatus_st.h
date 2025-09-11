/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file routerstatus_st.h
 * @brief Routerstatus (consensus entry) structure
 **/

#ifndef ROUTERSTATUS_ST_H
#define ROUTERSTATUS_ST_H

#include "feature/dirclient/download_status_st.h"

/** Contents of a single router entry in a network status object.
 */
struct routerstatus_t {
 /* This should be kept in sync with the function
 * routerstatus_has_visibly_changed and the printing function
 * routerstatus_format_entry in NS_CONTROL_PORT mode.
 */
  char nickname[MAX_NICKNAME_LEN+1]; /**< The nickname this router says it
                                      * has. */
  char identity_digest[DIGEST_LEN]; /**< Digest of the router's identity
                                     * key. */
  /** Digest of the router's most recent descriptor or microdescriptor.
   * If it's a descriptor, we only use the first DIGEST_LEN bytes. */
  char descriptor_digest[DIGEST256_LEN];
  tor_addr_t ipv4_addr;
  uint16_t ipv4_orport; /**< IPv4 OR port for this router. */
  uint16_t ipv4_dirport; /**< Directory port for this router. */
  tor_addr_t ipv6_addr; /**< IPv6 address for this router. */
  uint16_t ipv6_orport; /**< IPv6 OR port for this router. */
  unsigned int is_authority:1; /**< True iff this router is an authority. */
  unsigned int is_exit:1; /**< True iff this router is a good exit. */
  unsigned int is_stable:1; /**< True iff this router stays up a long time. */
  unsigned int is_fast:1; /**< True iff this router has good bandwidth. */
  /** True iff this router is called 'running' in the consensus. We give it
   * this funny name so that we don't accidentally use this bit as a view of
   * whether we think the router is *currently* running.  If that's what you
   * want to know, look at is_running in node_t. */
  unsigned int is_flagged_running:1;
  unsigned int is_named:1; /**< True iff "nickname" belongs to this router. */
  unsigned int is_unnamed:1; /**< True iff "nickname" belongs to another
                              * router. */
  unsigned int is_valid:1; /**< True iff this router isn't invalid. */
  unsigned int is_possible_guard:1; /**< True iff this router would be a good
                                     * choice as an entry guard. */
  unsigned int is_bad_exit:1; /**< True iff this node is a bad choice for
                               * an exit node. */
  unsigned int is_middle_only:1; /**< True iff this node is marked as bad
                                  * for anything besides middle positions. */
  unsigned int is_hs_dir:1; /**< True iff this router is a v2-or-later hidden
                             * service directory. */
  unsigned int is_v2_dir:1; /** True iff this router publishes an open DirPort
                             * or it claims to accept tunnelled dir requests.
                             */
  unsigned int is_staledesc:1; /** True iff the authorities think this router
                                * should upload a new descriptor soon. */
  unsigned int is_sybil:1; /** True iff this router is a sybil. */

  unsigned int has_bandwidth:1; /**< The vote/consensus had bw info */
  unsigned int has_exitsummary:1; /**< The vote/consensus had exit summaries */
  unsigned int bw_is_unmeasured:1; /**< This is a consensus entry, with
                                    * the Unmeasured flag set. */

  /** Flags to summarize the protocol versions for this routerstatus_t. */
  protover_summary_flags_t pv;

  uint32_t bandwidth_kb; /**< Bandwidth (capacity) of the router as reported in
                       * the vote/consensus, in kilobytes/sec. */

  /** The consensus has guardfraction information for this router. */
  unsigned int has_guardfraction:1;
  /** The guardfraction value of this router. */
  uint32_t guardfraction_percentage;

  char *exitsummary; /**< exit policy summary -
                      * XXX weasel: this probably should not stay a string. */

  /* ---- The fields below aren't derived from the networkstatus; they
   * hold local information only. */

  time_t last_dir_503_at; /**< When did this router last tell us that it
                           * was too busy to serve directory info? */
  download_status_t dl_status;

};

#endif /* !defined(ROUTERSTATUS_ST_H) */
