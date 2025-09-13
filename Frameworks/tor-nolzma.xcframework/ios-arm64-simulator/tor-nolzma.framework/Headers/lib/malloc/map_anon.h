/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file map_anon.h
 * \brief Headers for map_anon.c
 **/

#ifndef TOR_MAP_ANON_H
#define TOR_MAP_ANON_H

#include "lib/malloc/malloc.h"
#include <stddef.h>

/**
 * When this flag is specified, try to prevent the mapping from being
 * swapped or dumped.
 *
 * In some operating systems, this flag is not implemented.
 */
#define ANONMAP_PRIVATE   (1u<<0)
/**
 * When this flag is specified, try to prevent the mapping from being
 * inherited after a fork().  In some operating systems, trying to access it
 * afterwards will cause its contents to be zero.  In others, trying to access
 * it afterwards will cause a crash.
 *
 * In some operating systems, this flag is not implemented at all.
 */
#define ANONMAP_NOINHERIT (1u<<1)

typedef enum {
  /** Possible value for inherit_result_out: the memory will be kept
   * by any child process. */
  INHERIT_RES_KEEP=0,
  /** Possible value for inherit_result_out: the memory will be dropped in the
   * child process. Attempting to access it will likely cause a segfault. */
  INHERIT_RES_DROP,
  /** Possible value for inherit_result_out: the memory will be cleared in
   * the child process. */
  INHERIT_RES_ZERO
} inherit_res_t;

/* Here we define the NOINHERIT_CAN_FAIL macro if and only if
 * it's possible that ANONMAP_NOINHERIT might yield inheritable memory.
 */
#ifdef _WIN32
/* Windows can't fork, so NOINHERIT is never needed. */
#elif defined(HAVE_MINHERIT)
/* minherit() will always have a working MAP_INHERIT_NONE or MAP_INHERIT_ZERO.
 * NOINHERIT should always work.
 */
#elif defined(HAVE_MADVISE)
/* madvise() sometimes has neither MADV_DONTFORK and MADV_WIPEONFORK.
 * We need to be ready for the possibility it failed.
 *
 * (Linux added DONTFORK in 2.6.16 and WIPEONFORK in 4.14. If we someday
 * require 2.6.16 or later, we can assume that DONTFORK will work.)
 */
#define NOINHERIT_CAN_FAIL
#else
#define NOINHERIT_CAN_FAIL
#endif /* defined(_WIN32) || ... */

void *tor_mmap_anonymous(size_t sz, unsigned flags,
                         inherit_res_t *inherit_result_out);
void tor_munmap_anonymous(void *mapping, size_t sz);

#endif /* !defined(TOR_MAP_ANON_H) */
