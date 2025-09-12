/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file desc_store_st.h
 * @brief Routerinfo/extrainfo storage structure.
 **/

#ifndef DESC_STORE_ST_H
#define DESC_STORE_ST_H

/** Allowable types of desc_store_t. */
typedef enum store_type_t {
  ROUTER_STORE = 0,
  EXTRAINFO_STORE = 1
} store_type_t;

/** A 'store' is a set of descriptors saved on disk, with accompanying
 * journal, mmaped as needed, rebuilt as needed. */
struct desc_store_t {
  /** Filename (within DataDir) for the store.  We append .tmp to this
   * filename for a temporary file when rebuilding the store, and .new to this
   * filename for the journal. */
  const char *fname_base;
  /** Human-readable description of what this store contains. */
  const char *description;

  tor_mmap_t *mmap; /**< A mmap for the main file in the store. */

  store_type_t type; /**< What's stored in this store? */

  /** The size of the router log, in bytes. */
  size_t journal_len;
  /** The size of the router store, in bytes. */
  size_t store_len;
  /** Total bytes dropped since last rebuild: this is space currently
   * used in the cache and the journal that could be freed by a rebuild. */
  size_t bytes_dropped;
};

#endif /* !defined(DESC_STORE_ST_H) */
