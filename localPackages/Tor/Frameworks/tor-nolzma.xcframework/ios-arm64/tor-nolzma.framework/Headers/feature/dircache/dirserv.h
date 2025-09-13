/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dirserv.h
 * \brief Header file for dirserv.c.
 **/

#ifndef TOR_DIRSERV_H
#define TOR_DIRSERV_H

struct ed25519_public_key_t;

#include "lib/testsupport/testsupport.h"

/** Ways to convert a spoolable_resource_t to a bunch of bytes. */
typedef enum dir_spool_source_t {
    DIR_SPOOL_SERVER_BY_DIGEST=1, DIR_SPOOL_SERVER_BY_FP,
    DIR_SPOOL_EXTRA_BY_DIGEST, DIR_SPOOL_EXTRA_BY_FP,
    DIR_SPOOL_MICRODESC,
    DIR_SPOOL_NETWORKSTATUS,
    DIR_SPOOL_CONSENSUS_CACHE_ENTRY,
} dir_spool_source_t;
#define dir_spool_source_bitfield_t ENUM_BF(dir_spool_source_t)

/** Object to remember the identity of an object that we are spooling,
 * or about to spool, in response to a directory request.
 *
 * (Why do we spool?  Because some directory responses are very large,
 * and we don't want to just shove the complete answer into the output
 * buffer: that would take a ridiculous amount of RAM.)
 *
 * If the spooled resource is relatively small (like microdescriptors,
 * descriptors, etc), we look them up by ID as needed, and add the whole
 * thing onto the output buffer at once.  If the spooled reseource is
 * big (like networkstatus documents), we reference-count it, and add it
 * a few K at a time.
 */
typedef struct spooled_resource_t {
  /**
   * If true, we add the entire object to the outbuf.  If false,
   * we spool the object a few K at a time.
   */
  unsigned spool_eagerly : 1;
  /**
   * Tells us what kind of object to get, and how to look it up.
   */
  dir_spool_source_bitfield_t spool_source : 7;
  /**
   * Tells us the specific object to spool.
   */
  uint8_t digest[DIGEST256_LEN];
  /**
   * A large object that we're spooling. Holds a reference count.  Only
   * used when spool_eagerly is false.
   */
  struct cached_dir_t *cached_dir_ref;
  /**
   * A different kind of large object that we might be spooling. Also
   * reference-counted.  Also only used when spool_eagerly is false.
   */
  struct consensus_cache_entry_t *consensus_cache_entry;
  const uint8_t *cce_body;
  size_t cce_len;
  /**
   * The current offset into cached_dir or cce_body. Only used when
   * spool_eagerly is false */
  off_t cached_dir_offset;
} spooled_resource_t;

int connection_dirserv_flushed_some(dir_connection_t *conn);

enum dir_spool_source_t;
int dir_split_resource_into_spoolable(const char *resource,
                                      enum dir_spool_source_t source,
                                      smartlist_t *spool_out,
                                      int *compressed_out,
                                      int flags);

#ifdef HAVE_MODULE_DIRCACHE
/** Is the dircache module enabled? */
#define have_module_dircache() (1)
int directory_caches_unknown_auth_certs(const or_options_t *options);
int directory_caches_dir_info(const or_options_t *options);
int directory_permits_begindir_requests(const or_options_t *options);
MOCK_DECL(cached_dir_t *, dirserv_get_consensus, (const char *flavor_name));
void dirserv_set_cached_consensus_networkstatus(const char *consensus,
                                              size_t consensus_len,
                                              const char *flavor_name,
                                              const common_digests_t *digests,
                                              const uint8_t *sha3_as_signed,
                                              time_t published);
#else /* !defined(HAVE_MODULE_DIRCACHE) */
#define have_module_dircache() (0)
#define directory_caches_unknown_auth_certs(opt) \
  ((void)(opt), 0)
#define directory_caches_dir_info(opt) \
  ((void)(opt), 0)
#define directory_permits_begindir_requests(opt) \
  ((void)(opt), 0)
#define dirserv_get_consensus(flav) \
  ((void)(flav), NULL)
#define dirserv_set_cached_consensus_networkstatus(a,b,c,d,e,f) \
  STMT_BEGIN {                                                  \
    (void)(a);                                                  \
    (void)(b);                                                  \
    (void)(c);                                                  \
    (void)(d);                                                  \
    (void)(e);                                                  \
    (void)(f);                                                  \
  } STMT_END
#endif /* defined(HAVE_MODULE_DIRCACHE) */

void dirserv_clear_old_networkstatuses(time_t cutoff);
int dirserv_get_routerdesc_spool(smartlist_t *spools_out, const char *key,
                                 dir_spool_source_t source,
                                 int conn_is_encrypted,
                                 const char **msg_out);

void dirserv_free_all(void);
void cached_dir_decref(cached_dir_t *d);
cached_dir_t *new_cached_dir(char *s, time_t published);

spooled_resource_t *spooled_resource_new(dir_spool_source_t source,
                                         const uint8_t *digest,
                                         size_t digestlen);
spooled_resource_t *spooled_resource_new_from_cache_entry(
                                      struct consensus_cache_entry_t *entry);
void spooled_resource_free_(spooled_resource_t *spooled);
#define spooled_resource_free(sp) \
  FREE_AND_NULL(spooled_resource_t, spooled_resource_free_, (sp))
void dirserv_spool_remove_missing_and_guess_size(dir_connection_t *conn,
                                                 time_t cutoff,
                                                 int compression,
                                                 size_t *size_out,
                                                 int *n_expired_out);
void dirserv_spool_sort(dir_connection_t *conn);
void dir_conn_clear_spool(dir_connection_t *conn);

#endif /* !defined(TOR_DIRSERV_H) */
