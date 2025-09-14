/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file di_ops.h
 * \brief Headers for di_ops.c
 **/

#ifndef TOR_DI_OPS_H
#define TOR_DI_OPS_H

#include "orconfig.h"
#include "lib/cc/torint.h"

int tor_memcmp(const void *a, const void *b, size_t sz);
int tor_memeq(const void *a, const void *b, size_t sz);
/** Perform a constant-time comparison of the <b>sz</b> bytes at <b>a</b> and
 * <b>b</b>, yielding true if they are different, and false otherwise. */
#define tor_memneq(a,b,sz) (!tor_memeq((a),(b),(sz)))

/** Alias for the platform's memcmp() function.  This function is
 * <em>not</em> data-independent: we define this alias so that we can
 * mark cases where we are deliberately using a data-dependent memcmp()
 * implementation.
 */
#define fast_memcmp(a,b,c) (memcmp((a),(b),(c)))
/** Alias for the platform's memcmp() function, for use in testing equality.
 *
 * This function is <em>not</em> data-independent: we define this alias so
 * that we can mark cases where we are deliberately using a data-dependent
 * memcmp() implementation.
 */
#define fast_memeq(a,b,c)  (0==memcmp((a),(b),(c)))
/** Alias for the platform's memcmp() function, for use in testing inequality.
 *
 * This function is <em>not</em> data-independent: we define this alias so
 * that we can mark cases where we are deliberately using a data-dependent
 * memcmp() implementation.
 */
#define fast_memneq(a,b,c) (0!=memcmp((a),(b),(c)))

int safe_mem_is_zero(const void *mem, size_t sz);

/** A type for a map from DIGEST256_LEN-byte blobs to void*, such that
 * data lookups take an amount of time proportional only to the size
 * of the map, and not to the position or presence of the item in the map.
 *
 * Not efficient for large maps! */
typedef struct di_digest256_map_t di_digest256_map_t;
/**
 * Type for a function used to free members of a di_digest256_map_t.
 **/
typedef void (*dimap_free_fn)(void *);

void dimap_free_(di_digest256_map_t *map, dimap_free_fn free_fn);
/**
 * @copydoc dimap_free_
 *
 * Additionally, set the pointer <b>map</b> to NULL.
 **/
#define dimap_free(map, free_fn)                \
  do {                                          \
    dimap_free_((map), (free_fn));              \
    (map) = NULL;                               \
  } while (0)
void dimap_add_entry(di_digest256_map_t **map,
                     const uint8_t *key, void *val);
void *dimap_search(const di_digest256_map_t *map, const uint8_t *key,
                   void *dflt_val);
int select_array_member_cumulative_timei(const uint64_t *entries,
                                         int n_entries,
                                         uint64_t total, uint64_t rand_val);

void memcpy_if_true_timei(bool s, void *dest, const void *src, size_t n);

#endif /* !defined(TOR_DI_OPS_H) */
