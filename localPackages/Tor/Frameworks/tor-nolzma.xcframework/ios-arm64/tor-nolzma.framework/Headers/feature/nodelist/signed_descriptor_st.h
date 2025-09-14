/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file signed_descriptor_st.h
 * @brief Descriptor/extrainfo signature structure
 **/

#ifndef SIGNED_DESCRIPTOR_ST_H
#define SIGNED_DESCRIPTOR_ST_H

#include "feature/dirclient/download_status_st.h"

/** Information need to cache an onion router's descriptor. */
struct signed_descriptor_t {
  /** Pointer to the raw server descriptor, preceded by annotations.  Not
   * necessarily NUL-terminated.  If saved_location is SAVED_IN_CACHE, this
   * pointer is null. */
  char *signed_descriptor_body;
  /** Length of the annotations preceding the server descriptor. */
  size_t annotations_len;
  /** Length of the server descriptor. */
  size_t signed_descriptor_len;
  /** Digest of the server descriptor, computed as specified in
   * dir-spec.txt. */
  char signed_descriptor_digest[DIGEST_LEN];
  /** Identity digest of the router. */
  char identity_digest[DIGEST_LEN];
  /** Declared publication time of the descriptor. */
  time_t published_on;
  /** For routerdescs only: digest of the corresponding extrainfo. */
  char extra_info_digest[DIGEST_LEN];
  /** For routerdescs only: A SHA256-digest of the extrainfo (if any) */
  char extra_info_digest256[DIGEST256_LEN];
  /** Certificate for ed25519 signing key. */
  struct tor_cert_st *signing_key_cert;
  /** For routerdescs only: Status of downloading the corresponding
   * extrainfo. */
  download_status_t ei_dl_status;
  /** Where is the descriptor saved? */
  saved_location_t saved_location;
  /** If saved_location is SAVED_IN_CACHE or SAVED_IN_JOURNAL, the offset of
   * this descriptor in the corresponding file. */
  off_t saved_offset;
  /** What position is this descriptor within routerlist->routers or
   * routerlist->old_routers? -1 for none. */
  int routerlist_index;
  /** The valid-until time of the most recent consensus that listed this
   * descriptor.  0 for "never listed in a consensus, so far as we know." */
  time_t last_listed_as_valid_until;
  /* If true, we do not ever try to save this object in the cache. */
  unsigned int do_not_cache : 1;
  /* If true, this item is meant to represent an extrainfo. */
  unsigned int is_extrainfo : 1;
  /* If true, we got an extrainfo for this item, and the digest was right,
   * but it was incompatible. */
  unsigned int extrainfo_is_bogus : 1;
  /* If true, we are willing to transmit this item unencrypted. */
  unsigned int send_unencrypted : 1;
};

#endif /* !defined(SIGNED_DESCRIPTOR_ST_H) */
