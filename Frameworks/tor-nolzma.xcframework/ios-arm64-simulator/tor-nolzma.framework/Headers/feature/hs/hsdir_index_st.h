/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file hsdir_index_st.h
 * @brief HS directory index structure
 **/

#ifndef HSDIR_INDEX_ST_H
#define HSDIR_INDEX_ST_H

/** Hidden service directory index used in a node_t which is set once we set
 * the consensus. */
struct hsdir_index_t {
  /** HSDir index to use when fetching a descriptor. */
  uint8_t fetch[DIGEST256_LEN];

  /** HSDir index used by services to store their first and second
   * descriptor. The first descriptor is chronologically older than the second
   * one and uses older TP and SRV values. */
  uint8_t store_first[DIGEST256_LEN];
  /** Newer index, for second descriptor. */
  uint8_t store_second[DIGEST256_LEN];
};

#endif /* !defined(HSDIR_INDEX_ST_H) */
