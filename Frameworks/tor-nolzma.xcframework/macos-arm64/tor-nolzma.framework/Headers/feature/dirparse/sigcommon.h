/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file sigcommon.h
 * \brief Header file for sigcommon.c.
 **/

#ifndef TOR_SIGCOMMON_H
#define TOR_SIGCOMMON_H

/* TODO: Rename all of these functions */
int router_get_hash_impl(const char *s, size_t s_len, char *digest,
                         const char *start_str, const char *end_str,
                         char end_char,
                         digest_algorithm_t alg);

#define CST_NO_CHECK_OBJTYPE  (1<<0)
struct directory_token_t;
MOCK_DECL(int, check_signature_token,(const char *digest,
                                     ssize_t digest_len,
                                     struct directory_token_t *tok,
                                     crypto_pk_t *pkey,
                                     int flags,
                                     const char *doctype));

int router_get_hash_impl_helper(const char *s, size_t s_len,
                            const char *start_str,
                            const char *end_str, char end_c,
                            int log_severity,
                            const char **start_out, const char **end_out);
int router_get_hashes_impl(const char *s, size_t s_len,
                           common_digests_t *digests,
                           const char *start_str, const char *end_str,
                           char end_char);

#ifdef SIGCOMMON_PRIVATE
MOCK_DECL(STATIC int, signed_digest_equals,
          (const uint8_t *d1, const uint8_t *d2, size_t len));
MOCK_DECL(STATIC int, router_compute_hash_final,(char *digest,
                           const char *start, size_t len,
                           digest_algorithm_t alg));
#endif /* defined(SIGCOMMON_PRIVATE) */

#endif /* !defined(TOR_SIGCOMMON_H) */
