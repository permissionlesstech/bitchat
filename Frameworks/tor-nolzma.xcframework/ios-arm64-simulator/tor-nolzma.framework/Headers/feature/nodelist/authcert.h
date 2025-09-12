/* Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file authcert.h
 * \brief Header file for authcert.c
 **/

#ifndef TOR_AUTHCERT_H
#define TOR_AUTHCERT_H

#include "lib/testsupport/testsupport.h"

int trusted_dirs_reload_certs(void);

/*
 * Pass one of these as source to trusted_dirs_load_certs_from_string()
 * to indicate whence string originates; this controls error handling
 * behavior such as marking downloads as failed.
 */

#define TRUSTED_DIRS_CERTS_SRC_SELF 0
#define TRUSTED_DIRS_CERTS_SRC_FROM_STORE 1
#define TRUSTED_DIRS_CERTS_SRC_DL_BY_ID_DIGEST 2
#define TRUSTED_DIRS_CERTS_SRC_DL_BY_ID_SK_DIGEST 3
#define TRUSTED_DIRS_CERTS_SRC_FROM_VOTE 4

int trusted_dirs_load_certs_from_string(const char *contents, int source,
                                        int flush, const char *source_dir);
void trusted_dirs_remove_old_certs(void);
void trusted_dirs_flush_certs_to_disk(void);
authority_cert_t *authority_cert_get_newest_by_id(const char *id_digest);
authority_cert_t *authority_cert_get_by_sk_digest(const char *sk_digest);
authority_cert_t *authority_cert_get_by_digests(const char *id_digest,
                                                const char *sk_digest);
void authority_cert_get_all(smartlist_t *certs_out);
void authority_cert_dl_failed(const char *id_digest,
                              const char *signing_key_digest, int status);
void authority_certs_fetch_missing(networkstatus_t *status, time_t now,
                                   const char *dir_hint);
int authority_cert_dl_looks_uncertain(const char *id_digest);
int authority_cert_is_denylisted(const authority_cert_t *cert);

void authority_cert_free_(authority_cert_t *cert);
#define authority_cert_free(cert) \
  FREE_AND_NULL(authority_cert_t, authority_cert_free_, (cert))

MOCK_DECL(smartlist_t *, list_authority_ids_with_downloads, (void));
MOCK_DECL(download_status_t *, id_only_download_status_for_authority_id,
          (const char *digest));
MOCK_DECL(smartlist_t *, list_sk_digests_for_authority_id,
          (const char *digest));
MOCK_DECL(download_status_t *, download_status_for_authority_id_and_sk,
    (const char *id_digest, const char *sk_digest));

void authcert_free_all(void);

#endif /* !defined(TOR_AUTHCERT_H) */
