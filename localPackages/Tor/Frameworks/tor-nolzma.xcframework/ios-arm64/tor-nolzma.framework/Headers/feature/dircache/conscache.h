/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file conscache.h
 * @brief Header for conscache.c
 **/

#ifndef TOR_CONSCACHE_H
#define TOR_CONSCACHE_H

#include "lib/container/handles.h"

typedef struct consensus_cache_entry_t consensus_cache_entry_t;
typedef struct consensus_cache_t consensus_cache_t;

struct config_line_t;

HANDLE_DECL(consensus_cache_entry, consensus_cache_entry_t, )
#define consensus_cache_entry_handle_free(h)    \
  FREE_AND_NULL(consensus_cache_entry_handle_t, \
                consensus_cache_entry_handle_free_, (h))

consensus_cache_t *consensus_cache_open(const char *subdir, int max_entries);
void consensus_cache_free_(consensus_cache_t *cache);
#define consensus_cache_free(cache) \
  FREE_AND_NULL(consensus_cache_t, consensus_cache_free_, (cache))
struct sandbox_cfg_elem_t;
int consensus_cache_may_overallocate(consensus_cache_t *cache);
int consensus_cache_register_with_sandbox(consensus_cache_t *cache,
                                          struct sandbox_cfg_elem_t **cfg);
void consensus_cache_unmap_lazy(consensus_cache_t *cache, time_t cutoff);
void consensus_cache_delete_pending(consensus_cache_t *cache,
                                    int force);
int consensus_cache_get_n_filenames_available(consensus_cache_t *cache);
consensus_cache_entry_t *consensus_cache_add(consensus_cache_t *cache,
                                           const struct config_line_t *labels,
                                           const uint8_t *data,
                                           size_t datalen);

consensus_cache_entry_t *consensus_cache_find_first(
                                             consensus_cache_t *cache,
                                             const char *key,
                                             const char *value);

void consensus_cache_find_all(smartlist_t *out,
                              consensus_cache_t *cache,
                              const char *key,
                              const char *value);
void consensus_cache_filter_list(smartlist_t *lst,
                                 const char *key,
                                 const char *value);

const char *consensus_cache_entry_get_value(const consensus_cache_entry_t *ent,
                                            const char *key);
const struct config_line_t *consensus_cache_entry_get_labels(
                                          const consensus_cache_entry_t *ent);

void consensus_cache_entry_incref(consensus_cache_entry_t *ent);
void consensus_cache_entry_decref(consensus_cache_entry_t *ent);

void consensus_cache_entry_mark_for_removal(consensus_cache_entry_t *ent);
void consensus_cache_entry_mark_for_aggressive_release(
                                            consensus_cache_entry_t *ent);
int consensus_cache_entry_get_body(const consensus_cache_entry_t *ent,
                                   const uint8_t **body_out,
                                   size_t *sz_out);

#ifdef TOR_UNIT_TESTS
int consensus_cache_entry_is_mapped(consensus_cache_entry_t *ent);
#endif

#endif /* !defined(TOR_CONSCACHE_H) */
