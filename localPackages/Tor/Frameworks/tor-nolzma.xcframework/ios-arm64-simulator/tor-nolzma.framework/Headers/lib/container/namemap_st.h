/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef NAMEMAP_ST_H
#define NAMEMAP_ST_H

/**
 * @file namemap_st.h
 * @brief Internal declarations for namemap structure.
 **/

#include "lib/cc/compat_compiler.h"
#include "ext/ht.h"

struct smartlist_t;

/** Longest allowed name that's allowed in a namemap_t. */
#define MAX_NAMEMAP_NAME_LEN 128

/** An entry inside a namemap_t. Maps a string to a numeric identifier. */
typedef struct mapped_name_t {
  HT_ENTRY(mapped_name_t) node;
  unsigned intval;
  char name[FLEXIBLE_ARRAY_MEMBER];
} mapped_name_t;

/** A structure that allocates small numeric identifiers for names and maps
 * back and forth between them.  */
struct namemap_t {
  HT_HEAD(namemap_ht, mapped_name_t) ht;
  struct smartlist_t *names;
};

#ifndef COCCI
/** Macro to initialize a namemap. */
#define NAMEMAP_INIT() { HT_INITIALIZER(), NULL }
#endif

#endif /* !defined(NAMEMAP_ST_H) */
