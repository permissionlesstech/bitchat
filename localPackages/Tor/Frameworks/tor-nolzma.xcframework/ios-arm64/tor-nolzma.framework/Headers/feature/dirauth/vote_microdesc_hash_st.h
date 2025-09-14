/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file vote_microdesc_hash_st.h
 * @brief Microdescriptor-hash voting structure.
 **/

#ifndef VOTE_MICRODESC_HASH_ST_H
#define VOTE_MICRODESC_HASH_ST_H

/** Linked list of microdesc hash lines for a single router in a directory
 * vote.
 */
struct vote_microdesc_hash_t {
  /** Next element in the list, or NULL. */
  struct vote_microdesc_hash_t *next;
  /** The raw contents of the microdesc hash line, from the "m" through the
   * newline. */
  char *microdesc_hash_line;
};

#endif /* !defined(VOTE_MICRODESC_HASH_ST_H) */
