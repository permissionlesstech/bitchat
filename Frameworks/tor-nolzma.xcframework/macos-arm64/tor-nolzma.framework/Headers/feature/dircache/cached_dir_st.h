/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file cached_dir_st.h
 * @brief Cached large directory object structure.
 **/

#ifndef CACHED_DIR_ST_H
#define CACHED_DIR_ST_H

/** A cached_dir_t represents a cacheable directory object, along with its
 * compressed form. */
struct cached_dir_t {
  char *dir; /**< Contents of this object, NUL-terminated. */
  char *dir_compressed; /**< Compressed contents of this object. */
  size_t dir_len; /**< Length of <b>dir</b> (not counting its NUL). */
  size_t dir_compressed_len; /**< Length of <b>dir_compressed</b>. */
  time_t published; /**< When was this object published. */
  common_digests_t digests; /**< Digests of this object (networkstatus only) */
  /** Sha3 digest (also ns only) */
  uint8_t digest_sha3_as_signed[DIGEST256_LEN];
  int refcnt; /**< Reference count for this cached_dir_t. */
};

#endif /* !defined(CACHED_DIR_ST_H) */
