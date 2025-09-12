/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file networkstatus_st.h
 * @brief Networkstatus consensus/vote structure.
 **/

#ifndef NETWORKSTATUS_ST_H
#define NETWORKSTATUS_ST_H

#include "feature/nodelist/networkstatus_sr_info_st.h"

/** Enumerates the possible seriousness values of a networkstatus document. */
typedef enum networkstatus_type_t {
  NS_TYPE_VOTE,
  NS_TYPE_CONSENSUS,
  NS_TYPE_OPINION,
} networkstatus_type_t;

/** A common structure to hold a v3 network status vote, or a v3 network
 * status consensus. */
struct networkstatus_t {
  networkstatus_type_t type; /**< Vote, consensus, or opinion? */
  consensus_flavor_t flavor; /**< If a consensus, what kind? */
  unsigned int has_measured_bws : 1;/**< True iff this networkstatus contains
                                     * measured= bandwidth values. */

  time_t published; /**< Vote only: Time when vote was written. */
  time_t valid_after; /**< Time after which this vote or consensus applies. */
  time_t fresh_until; /**< Time before which this is the most recent vote or
                       * consensus. */
  time_t valid_until; /**< Time after which this vote or consensus should not
                       * be used. */

  /** Consensus only: what method was used to produce this consensus? */
  int consensus_method;
  /** Vote only: what methods is this voter willing to use? */
  smartlist_t *supported_methods;

  /** List of 'package' lines describing hashes of downloadable packages */
  smartlist_t *package_lines;

  /** How long does this vote/consensus claim that authorities take to
   * distribute their votes to one another? */
  int vote_seconds;
  /** How long does this vote/consensus claim that authorities take to
   * distribute their consensus signatures to one another? */
  int dist_seconds;

  /** Comma-separated list of recommended client software, or NULL if this
   * voter has no opinion. */
  char *client_versions;
  char *server_versions;

  /** Lists of subprotocol versions which are _recommended_ for relays and
   * clients, or which are _require_ for relays and clients. Tor shouldn't
   * make any more network connections if a required protocol is missing.
   */
  char *recommended_relay_protocols;
  char *recommended_client_protocols;
  char *required_relay_protocols;
  char *required_client_protocols;

  /** List of flags that this vote/consensus applies to routers.  If a flag is
   * not listed here, the voter has no opinion on what its value should be. */
  smartlist_t *known_flags;

  /** List of key=value strings for the parameters in this vote or
   * consensus, sorted by key. */
  smartlist_t *net_params;

  /** List of key=value strings for the bw weight parameters in the
   * consensus. */
  smartlist_t *weight_params;

  /** List of networkstatus_voter_info_t.  For a vote, only one element
   * is included.  For a consensus, one element is included for every voter
   * whose vote contributed to the consensus. */
  smartlist_t *voters;

  struct authority_cert_t *cert; /**< Vote only: the voter's certificate. */

  /** Digests of this document, as signed. */
  common_digests_t digests;
  /** A SHA3-256 digest of the document, not including signatures: used for
   * consensus diffs */
  uint8_t digest_sha3_as_signed[DIGEST256_LEN];

  /** List of router statuses, sorted by identity digest.  For a vote,
   * the elements are vote_routerstatus_t; for a consensus, the elements
   * are routerstatus_t. */
  smartlist_t *routerstatus_list;

  /** If present, a map from descriptor digest to elements of
   * routerstatus_list. */
  digestmap_t *desc_digest_map;

  /** Contains the shared random protocol data from a vote or consensus. */
  networkstatus_sr_info_t sr_info;

  /** List of key=value strings from the headers of the bandwidth list file */
  smartlist_t *bw_file_headers;

  /** A SHA256 digest of the bandwidth file used in a vote. */
  uint8_t bw_file_digest256[DIGEST256_LEN];
};

#endif /* !defined(NETWORKSTATUS_ST_H) */
