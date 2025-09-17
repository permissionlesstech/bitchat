/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_cache.h
 * \brief Header file for hs_cache.c
 **/

#ifndef TOR_HS_CACHE_H
#define TOR_HS_CACHE_H

#include <stdint.h>

#include "feature/hs/hs_common.h"
#include "feature/hs/hs_descriptor.h"
#include "feature/hs/hs_ident.h"
#include "feature/rend/rendcommon.h"
#include "feature/nodelist/torcert.h"

struct ed25519_public_key_t;

/** This is the maximum time an introduction point state object can stay in the
 * client cache in seconds (2 mins or 120 seconds). */
#define HS_CACHE_CLIENT_INTRO_STATE_MAX_AGE (2 * 60)
/** How old do we let hidden service descriptors get before discarding
 * them as too old? */
#define HS_CACHE_MAX_AGE (2*24*60*60)
/** How wrong do we assume our clock may be when checking whether hidden
 * services are too old or too new? */
#define HS_CACHE_MAX_SKEW (24*60*60)
/** How old do we keep an intro point failure entry in the failure cache? */
#define HS_CACHE_FAILURE_MAX_AGE (5*60)

/** Introduction point state. */
typedef struct hs_cache_intro_state_t {
  /** When this entry was created and put in the cache. */
  time_t created_ts;

  /** Did it suffered a generic error? */
  unsigned int error : 1;

  /** Did it timed out? */
  unsigned int timed_out : 1;

  /** How many times we tried to reached it and it was unreachable. */
  uint32_t unreachable_count;
} hs_cache_intro_state_t;

typedef struct hs_cache_client_intro_state_t {
  /** Contains hs_cache_intro_state_t object indexed by introduction point
   * authentication key. */
  digest256map_t *intro_points;
} hs_cache_client_intro_state_t;

/** Descriptor representation on the directory side which is a subset of
 * information that the HSDir can decode and serve it. */
typedef struct hs_cache_dir_descriptor_t {
  /** This object is indexed using the blinded pubkey located in the plaintext
   * data which is populated only once the descriptor has been successfully
   * decoded and validated. This simply points to that pubkey. */
  const uint8_t *key;

  /** When does this entry has been created. Used to expire entries. */
  time_t created_ts;

  /** Descriptor plaintext information. Obviously, we can't decrypt the
   * encrypted part of the descriptor. */
  hs_desc_plaintext_data_t *plaintext_data;
  /** Encoded descriptor which is basically in text form. It's a NUL terminated
   * string thus safe to strlen(). */
  char *encoded_desc;
  /** How many times this descriptor has been downloaded. We use this as an
   * heuristic for the OOM cache cleaning. It is very large so we avoid an kind
   * of possible wrapping. */
  uint64_t n_downloaded;
} hs_cache_dir_descriptor_t;

/* Public API */

/* Return maximum lifetime in seconds of a cache entry. */
static inline time_t
hs_cache_max_entry_lifetime(void)
{
  return HS_CACHE_MAX_AGE + HS_CACHE_MAX_SKEW;
}

void hs_cache_init(void);
void hs_cache_free_all(void);
void hs_cache_clean_as_dir(time_t now);
size_t hs_cache_handle_oom(size_t min_remove_bytes);

unsigned int hs_cache_get_max_descriptor_size(void);

/* Store and Lookup function. They are version agnostic that is depending on
 * the requested version of the descriptor, it will be re-routed to the
 * right function. */
int hs_cache_store_as_dir(const char *desc);
int hs_cache_lookup_as_dir(uint32_t version, const char *query,
                           const char **desc_out);
void hs_cache_mark_dowloaded_as_dir(const hs_ident_dir_conn_t *ident);

const hs_descriptor_t *
hs_cache_lookup_as_client(const struct ed25519_public_key_t *key);
const char *
hs_cache_lookup_encoded_as_client(const struct ed25519_public_key_t *key);
hs_desc_decode_status_t hs_cache_store_as_client(const char *desc_str,
                           const struct ed25519_public_key_t *identity_pk);
void hs_cache_remove_as_client(const struct ed25519_public_key_t *key);
void hs_cache_clean_as_client(time_t now);
void hs_cache_purge_as_client(void);

/* Client failure cache. */
void hs_cache_client_intro_state_note(
                              const struct ed25519_public_key_t *service_pk,
                              const struct ed25519_public_key_t *auth_key,
                              rend_intro_point_failure_t failure);
const hs_cache_intro_state_t *hs_cache_client_intro_state_find(
                              const struct ed25519_public_key_t *service_pk,
                              const struct ed25519_public_key_t *auth_key);
void hs_cache_client_intro_state_clean(time_t now);
void hs_cache_client_intro_state_purge(void);

bool hs_cache_client_new_auth_parse(const ed25519_public_key_t *service_pk);

size_t hs_cache_get_total_allocation(void);
void hs_cache_decrement_allocation(size_t n);
void hs_cache_increment_allocation(size_t n);

#ifdef HS_CACHE_PRIVATE
#include "lib/crypt_ops/crypto_ed25519.h"

/** Represents a locally cached HS descriptor on a hidden service client. */
typedef struct hs_cache_client_descriptor_t {
  /** This object is indexed using the service identity public key */
  struct ed25519_public_key_t key;

  /** When will this entry expire? We expire cached client descriptors in the
   * start of the next time period, since that's when clients need to start
   * using the next blinded key of the service. */
  time_t expiration_ts;

  /** The cached decoded descriptor, this object is the owner. This can be
   * NULL if the descriptor couldn't be decoded due to missing or bad client
   * authorization. It can be decoded later from the encoded_desc object if
   * the proper client authorization is given tor. */
  hs_descriptor_t *desc;

  /** Encoded descriptor in string form. Can't be NULL. */
  char *encoded_desc;
} hs_cache_client_descriptor_t;

STATIC size_t cache_clean_v3_as_dir(time_t now, time_t global_cutoff);
STATIC size_t cache_clean_v3_by_downloaded_as_dir(const uint64_t target,
                                           const size_t min_remove_bytes,
                                           uint64_t *next_lowest);
STATIC hs_cache_dir_descriptor_t *lookup_v3_desc_as_dir(const uint8_t *key);

STATIC hs_cache_client_descriptor_t *
lookup_v3_desc_as_client(const uint8_t *key);

#ifdef TOR_UNIT_TESTS
void dir_set_downloaded(const ed25519_public_key_t *pk, uint64_t value);
#endif /* TOR_UNIT_TESTS */

#endif /* defined(HS_CACHE_PRIVATE) */

#endif /* !defined(TOR_HS_CACHE_H) */
