/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file nodefamily_st.h
 * @brief Compact node-family structure
 **/

#ifndef TOR_NODEFAMILY_ST_H
#define TOR_NODEFAMILY_ST_H

#include "orconfig.h"
#include "ht.h"

struct nodefamily_t {
  /** Entry for this nodefamily_t within the hashtable. */
  HT_ENTRY(nodefamily_t) ht_ent;
  /** Reference count.  (The hashtable is not treated as a reference */
  uint32_t refcnt;
  /** Number of items encoded in <b>family_members</b>. */
  uint32_t n_members;
  /* A byte-array encoding the members of this family.  We encode each member
   * as one byte to indicate whether it's a nickname or a fingerprint, plus
   * DIGEST_LEN bytes of data.  The entries are lexically sorted.
   */
  uint8_t family_members[FLEXIBLE_ARRAY_MEMBER];
};

#define NODEFAMILY_MEMBER_LEN (1+DIGEST_LEN)

/** Tag byte, indicates that the following bytes are a RSA1024 SHA1 ID.
 */
#define NODEFAMILY_BY_RSA_ID 0
/** Tag byte, indicates that the following bytes are a NUL-padded nickname.
 */
#define NODEFAMILY_BY_NICKNAME 1

/**
 * Number of bytes to allocate in the array for a nodefamily_t with N members.
 **/
#define NODEFAMILY_ARRAY_SIZE(n) \
  ((n) * NODEFAMILY_MEMBER_LEN)

/**
 * Pointer to the i'th member of <b>nf</b>, as encoded.
 */
#define NODEFAMILY_MEMBER_PTR(nf, i) \
  (&((nf)->family_members[(i) * NODEFAMILY_MEMBER_LEN]))

#endif /* !defined(TOR_NODEFAMILY_ST_H) */
