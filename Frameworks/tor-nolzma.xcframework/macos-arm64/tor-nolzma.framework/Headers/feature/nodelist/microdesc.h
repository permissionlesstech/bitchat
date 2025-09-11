/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file microdesc.h
 * \brief Header file for microdesc.c.
 **/

#ifndef TOR_MICRODESC_H
#define TOR_MICRODESC_H

microdesc_cache_t *get_microdesc_cache(void);

void microdesc_check_counts(void);

smartlist_t *microdescs_add_to_cache(microdesc_cache_t *cache,
                        const char *s, const char *eos, saved_location_t where,
                        int no_save, time_t listed_at,
                        smartlist_t *requested_digests256);
smartlist_t *microdescs_add_list_to_cache(microdesc_cache_t *cache,
                        smartlist_t *descriptors, saved_location_t where,
                        int no_save);

void microdesc_cache_clean(microdesc_cache_t *cache, time_t cutoff, int force);
int microdesc_cache_rebuild(microdesc_cache_t *cache, int force);
int microdesc_cache_reload(microdesc_cache_t *cache);
void microdesc_cache_clear(microdesc_cache_t *cache);

microdesc_t *microdesc_cache_lookup_by_digest256(microdesc_cache_t *cache,
                                                 const char *d);

smartlist_t *microdesc_list_missing_digest256(networkstatus_t *ns,
                                              microdesc_cache_t *cache,
                                              int downloadable_only,
                                              digest256map_t *skip);

void microdesc_free_(microdesc_t *md, const char *fname, int line);
#define microdesc_free(md) do {                 \
    microdesc_free_((md), __FILE__, __LINE__);  \
    (md) = NULL;                                \
  } while (0)
void microdesc_free_all(void);

void update_microdesc_downloads(time_t now);
void update_microdescs_from_networkstatus(time_t now);

MOCK_DECL(int, usable_consensus_flavor,(void));
int we_fetch_microdescriptors(const or_options_t *options);
int we_fetch_router_descriptors(const or_options_t *options);
int we_use_microdescriptors_for_circuits(const or_options_t *options);

void microdesc_note_outdated_dirserver(const char *relay_digest);
int microdesc_relay_is_outdated_dirserver(const char *relay_digest);
void microdesc_reset_outdated_dirservers_list(void);

#endif /* !defined(TOR_MICRODESC_H) */

