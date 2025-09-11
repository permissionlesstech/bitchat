/* Copyright (c) 2013-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file fp_pair.h
 * \brief Header file for fp_pair.c.
 **/

#ifndef _TOR_FP_PAIR_H
#define _TOR_FP_PAIR_H

/** A pair of digests created by dir_split_resource_info_fingerprint_pairs() */
typedef struct {
  char first[DIGEST_LEN];
  char second[DIGEST_LEN];
} fp_pair_t;

/*
 * Declare fp_pair_map_t functions and structs
 */

typedef struct fp_pair_map_entry_t fp_pair_map_entry_t;
typedef struct fp_pair_map_t fp_pair_map_t;
typedef fp_pair_map_entry_t *fp_pair_map_iter_t;

fp_pair_map_t * fp_pair_map_new(void);
void * fp_pair_map_set(fp_pair_map_t *map, const fp_pair_t *key, void *val);
void * fp_pair_map_set_by_digests(fp_pair_map_t *map,
                                  const char *first, const char *second,
                                  void *val);
void * fp_pair_map_get(const fp_pair_map_t *map, const fp_pair_t *key);
void * fp_pair_map_get_by_digests(const fp_pair_map_t *map,
                                  const char *first, const char *second);
void * fp_pair_map_remove(fp_pair_map_t *map, const fp_pair_t *key);
void fp_pair_map_free_(fp_pair_map_t *map, void (*free_val)(void*));
#define fp_pair_map_free(map, free_val) do {            \
    fp_pair_map_free_((map), (free_val));               \
    (map) = NULL;                                       \
  } while (0)

int fp_pair_map_isempty(const fp_pair_map_t *map);
int fp_pair_map_size(const fp_pair_map_t *map);
fp_pair_map_iter_t * fp_pair_map_iter_init(fp_pair_map_t *map);
fp_pair_map_iter_t * fp_pair_map_iter_next(fp_pair_map_t *map,
                                           fp_pair_map_iter_t *iter);
fp_pair_map_iter_t * fp_pair_map_iter_next_rmv(fp_pair_map_t *map,
                                               fp_pair_map_iter_t *iter);
void fp_pair_map_iter_get(fp_pair_map_iter_t *iter,
                          fp_pair_t *key_out, void **val_out);
int fp_pair_map_iter_done(fp_pair_map_iter_t *iter);
void fp_pair_map_assert_ok(const fp_pair_map_t *map);

#undef DECLARE_MAP_FNS

#endif /* !defined(_TOR_FP_PAIR_H) */

