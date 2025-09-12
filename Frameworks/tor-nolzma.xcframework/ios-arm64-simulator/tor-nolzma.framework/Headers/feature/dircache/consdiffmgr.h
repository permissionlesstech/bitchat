/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file consdiffmgr.h
 * @brief Header for consdiffmgr.c
 **/

#ifndef TOR_CONSDIFFMGR_H
#define TOR_CONSDIFFMGR_H

enum compress_method_t;

/**
 * Possible outcomes from trying to look up a given consensus diff.
 */
typedef enum consdiff_status_t {
  CONSDIFF_AVAILABLE,
  CONSDIFF_NOT_FOUND,
  CONSDIFF_IN_PROGRESS,
} consdiff_status_t;

typedef struct consdiff_cfg_t {
  int32_t cache_max_num;
} consdiff_cfg_t;

struct consensus_cache_entry_t; // from conscache.h

int consdiffmgr_add_consensus(const char *consensus,
                              size_t consensus_len,
                              const networkstatus_t *as_parsed);

consdiff_status_t consdiffmgr_find_consensus(
                           struct consensus_cache_entry_t **entry_out,
                           consensus_flavor_t flavor,
                           enum compress_method_t method);

consdiff_status_t consdiffmgr_find_diff_from(
                           struct consensus_cache_entry_t **entry_out,
                           consensus_flavor_t flavor,
                           int digest_type,
                           const uint8_t *digest,
                           size_t digestlen,
                           enum compress_method_t method);

int consensus_cache_entry_get_voter_id_digests(
                                  const struct consensus_cache_entry_t *ent,
                                  smartlist_t *out);
int consensus_cache_entry_get_fresh_until(
                                  const struct consensus_cache_entry_t *ent,
                                  time_t *out);
int consensus_cache_entry_get_valid_until(
                                  const struct consensus_cache_entry_t *ent,
                                  time_t *out);
int consensus_cache_entry_get_valid_after(
                                  const struct consensus_cache_entry_t *ent,
                                  time_t *out);

void consdiffmgr_rescan(void);
int consdiffmgr_cleanup(void);
void consdiffmgr_enable_background_compression(void);
void consdiffmgr_configure(const consdiff_cfg_t *cfg);
struct sandbox_cfg_elem_t;
int consdiffmgr_register_with_sandbox(struct sandbox_cfg_elem_t **cfg);
void consdiffmgr_free_all(void);
int consdiffmgr_validate(void);

#ifdef CONSDIFFMGR_PRIVATE
struct consensus_cache_t;
struct consensus_cache_entry_t;
STATIC unsigned n_diff_compression_methods(void);
STATIC unsigned n_consensus_compression_methods(void);
STATIC struct consensus_cache_t *cdm_cache_get(void);
STATIC struct consensus_cache_entry_t *cdm_cache_lookup_consensus(
                          consensus_flavor_t flavor, time_t valid_after);
STATIC int cdm_entry_get_sha3_value(uint8_t *digest_out,
                                    struct consensus_cache_entry_t *ent,
                                    const char *label);
STATIC int uncompress_or_set_ptr(const char **out, size_t *outlen,
                                 char **owned_out,
                                 struct consensus_cache_entry_t *ent);
#endif /* defined(CONSDIFFMGR_PRIVATE) */

#ifdef TOR_UNIT_TESTS
int consdiffmgr_add_consensus_nulterm(const char *consensus,
                                      const networkstatus_t *as_parsed);
#endif

#endif /* !defined(TOR_CONSDIFFMGR_H) */
