/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file tortls_internal.h
 * @brief Declare internal functions for lib/tls
 **/

#ifndef TORTLS_INTERNAL_H
#define TORTLS_INTERNAL_H

#include "lib/tls/x509.h"

int tor_errno_to_tls_error(int e);
#ifdef ENABLE_OPENSSL
int tor_tls_get_error(tor_tls_t *tls, int r, int extra,
                  const char *doing, int severity, int domain);
#endif
MOCK_DECL(void, try_to_extract_certs_from_tls,
          (int severity, tor_tls_t *tls,
           tor_x509_cert_impl_t **cert_out,
           tor_x509_cert_impl_t **id_cert_out));

tor_tls_context_t *tor_tls_context_new(crypto_pk_t *identity,
                   unsigned int key_lifetime, unsigned flags, int is_client);
int tor_tls_context_init_one(tor_tls_context_t **ppcontext,
                             crypto_pk_t *identity,
                             unsigned int key_lifetime,
                             unsigned int flags,
                             int is_client);
int tor_tls_context_init_certificates(tor_tls_context_t *result,
                                      crypto_pk_t *identity,
                                      unsigned key_lifetime,
                                      unsigned flags);
void tor_tls_impl_free_(tor_tls_impl_t *ssl);
#define tor_tls_impl_free(tls) \
  FREE_AND_NULL(tor_tls_impl_t, tor_tls_impl_free_, (tls))

void tor_tls_context_impl_free_(tor_tls_context_impl_t *);
#define tor_tls_context_impl_free(ctx) \
  FREE_AND_NULL(tor_tls_context_impl_t, tor_tls_context_impl_free_, (ctx))

#ifdef ENABLE_OPENSSL
tor_tls_t *tor_tls_get_by_ssl(const struct ssl_st *ssl);
int tor_tls_client_is_using_v2_ciphers(const struct ssl_st *ssl);
void tor_tls_debug_state_callback(const struct ssl_st *ssl,
                                         int type, int val);
void tor_tls_server_info_callback(const struct ssl_st *ssl,
                                         int type, int val);
void tor_tls_allocate_tor_tls_object_ex_data_index(void);

#if !defined(HAVE_SSL_SESSION_GET_MASTER_KEY)
size_t SSL_SESSION_get_master_key(struct ssl_session_st *s,
                                  uint8_t *out,
                                  size_t len);
#endif

#ifdef TORTLS_OPENSSL_PRIVATE
int always_accept_verify_cb(int preverify_ok, X509_STORE_CTX *x509_ctx);
int tor_tls_classify_client_ciphers(const struct ssl_st *ssl,
                                           STACK_OF(SSL_CIPHER) *peer_ciphers);
STATIC int tor_tls_session_secret_cb(struct ssl_st *ssl, void *secret,
                            int *secret_len,
                            STACK_OF(SSL_CIPHER) *peer_ciphers,
                            CONST_IF_OPENSSL_1_1_API SSL_CIPHER **cipher,
                            void *arg);
STATIC int find_cipher_by_id(const SSL *ssl, const SSL_METHOD *m,
                             uint16_t cipher);
#endif /* defined(TORTLS_OPENSSL_PRIVATE) */
#endif /* defined(ENABLE_OPENSSL) */

#ifdef TOR_UNIT_TESTS
extern int tor_tls_object_ex_data_index;
extern tor_tls_context_t *server_tls_context;
extern tor_tls_context_t *client_tls_context;
extern uint16_t v2_cipher_list[];
extern uint64_t total_bytes_written_over_tls;
extern uint64_t total_bytes_written_by_tls;
#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TORTLS_INTERNAL_H) */
