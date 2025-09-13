/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_TORTLS_H
#define TOR_TORTLS_H

/**
 * \file tortls.h
 * \brief Headers for tortls.c
 **/

#include "lib/crypt_ops/crypto_rsa.h"
#include "lib/testsupport/testsupport.h"
#include "lib/net/nettypes.h"

/* Opaque structure to hold a TLS connection. */
typedef struct tor_tls_t tor_tls_t;

#ifdef TORTLS_PRIVATE
#ifdef ENABLE_OPENSSL
struct ssl_st;
struct ssl_ctx_st;
struct ssl_session_st;
typedef struct ssl_ctx_st tor_tls_context_impl_t;
typedef struct ssl_st tor_tls_impl_t;
#else /* !defined(ENABLE_OPENSSL) */
struct PRFileDesc;
typedef struct PRFileDesc tor_tls_context_impl_t;
typedef struct PRFileDesc tor_tls_impl_t;
#endif /* defined(ENABLE_OPENSSL) */
#endif /* defined(TORTLS_PRIVATE) */

struct tor_x509_cert_t;

/* Possible return values for most tor_tls_* functions. */
#define MIN_TOR_TLS_ERROR_VAL_     -9
#define TOR_TLS_ERROR_MISC         -9
/* Rename to unexpected close or something. XXXX */
#define TOR_TLS_ERROR_IO           -8
#define TOR_TLS_ERROR_CONNREFUSED  -7
#define TOR_TLS_ERROR_CONNRESET    -6
#define TOR_TLS_ERROR_NO_ROUTE     -5
#define TOR_TLS_ERROR_TIMEOUT      -4
#define TOR_TLS_CLOSE              -3
#define TOR_TLS_WANTREAD           -2
#define TOR_TLS_WANTWRITE          -1
#define TOR_TLS_DONE                0

/** Collection of case statements for all TLS errors that are not due to
 * underlying IO failure. */
#define CASE_TOR_TLS_ERROR_ANY_NONIO            \
  case TOR_TLS_ERROR_MISC:                      \
  case TOR_TLS_ERROR_CONNREFUSED:               \
  case TOR_TLS_ERROR_CONNRESET:                 \
  case TOR_TLS_ERROR_NO_ROUTE:                  \
  case TOR_TLS_ERROR_TIMEOUT

/** Use this macro in a switch statement to catch _any_ TLS error.  That way,
 * if more errors are added, your switches will still work. */
#define CASE_TOR_TLS_ERROR_ANY                  \
  CASE_TOR_TLS_ERROR_ANY_NONIO:                 \
  case TOR_TLS_ERROR_IO

#define TOR_TLS_IS_ERROR(rv) ((rv) < TOR_TLS_CLOSE)

/** Holds a SSL_CTX object and related state used to configure TLS
 * connections.
 */
typedef struct tor_tls_context_t tor_tls_context_t;

const char *tor_tls_err_to_string(int err);
void tor_tls_get_state_description(tor_tls_t *tls, char *buf, size_t sz);
void tor_tls_free_all(void);

#define TOR_TLS_CTX_IS_PUBLIC_SERVER (1u<<0)

void tor_tls_init(void);
void tls_log_errors(tor_tls_t *tls, int severity, int domain,
                    const char *doing);
const char *tor_tls_get_last_error_msg(const tor_tls_t *tls);
int tor_tls_context_init(unsigned flags,
                         crypto_pk_t *client_identity,
                         crypto_pk_t *server_identity,
                         unsigned int key_lifetime);
void tor_tls_context_incref(tor_tls_context_t *ctx);
void tor_tls_context_decref(tor_tls_context_t *ctx);
tor_tls_context_t *tor_tls_context_get(int is_server);
tor_tls_t *tor_tls_new(tor_socket_t sock, int is_server);
void tor_tls_set_logged_address(tor_tls_t *tls, const char *address);
void tor_tls_set_renegotiate_callback(tor_tls_t *tls,
                                      void (*cb)(tor_tls_t *, void *arg),
                                      void *arg);
int tor_tls_is_server(tor_tls_t *tls);
void tor_tls_release_socket(tor_tls_t *tls);
void tor_tls_free_(tor_tls_t *tls);
#define tor_tls_free(tls) FREE_AND_NULL(tor_tls_t, tor_tls_free_, (tls))
int tor_tls_peer_has_cert(tor_tls_t *tls);
MOCK_DECL(struct tor_x509_cert_t *,tor_tls_get_peer_cert,(tor_tls_t *tls));
MOCK_DECL(struct tor_x509_cert_t *,tor_tls_get_own_cert,(tor_tls_t *tls));
int tor_tls_verify(int severity, tor_tls_t *tls, crypto_pk_t **identity);
MOCK_DECL(int, tor_tls_read, (tor_tls_t *tls, char *cp, size_t len));
int tor_tls_write(tor_tls_t *tls, const char *cp, size_t n);
int tor_tls_handshake(tor_tls_t *tls);
int tor_tls_finish_handshake(tor_tls_t *tls);
void tor_tls_unblock_renegotiation(tor_tls_t *tls);
void tor_tls_block_renegotiation(tor_tls_t *tls);
int tor_tls_get_pending_bytes(tor_tls_t *tls);
size_t tor_tls_get_forced_write_size(tor_tls_t *tls);

void tor_tls_get_n_raw_bytes(tor_tls_t *tls,
                             size_t *n_read, size_t *n_written);

int tor_tls_get_buffer_sizes(tor_tls_t *tls,
                              size_t *rbuf_capacity, size_t *rbuf_bytes,
                              size_t *wbuf_capacity, size_t *wbuf_bytes);

MOCK_DECL(double, tls_get_write_overhead_ratio, (void));

int tor_tls_used_v1_handshake(tor_tls_t *tls);
int tor_tls_get_num_server_handshakes(tor_tls_t *tls);
int tor_tls_server_got_renegotiate(tor_tls_t *tls);
MOCK_DECL(int,tor_tls_cert_matches_key,(const tor_tls_t *tls,
                                        const struct tor_x509_cert_t *cert));
MOCK_DECL(int,tor_tls_get_tlssecrets,(tor_tls_t *tls, uint8_t *secrets_out));
#ifdef ENABLE_OPENSSL
/* OpenSSL lets us see these master secrets; NSS sensibly does not. */
#define HAVE_WORKING_TOR_TLS_GET_TLSSECRETS
#endif
MOCK_DECL(int,tor_tls_export_key_material,(
                     tor_tls_t *tls, uint8_t *secrets_out,
                     const uint8_t *context,
                     size_t context_len,
                     const char *label));

#ifdef ENABLE_OPENSSL
/* Log and abort if there are unhandled TLS errors in OpenSSL's error stack.
 */
#define check_no_tls_errors() check_no_tls_errors_(__FILE__,__LINE__)
void check_no_tls_errors_(const char *fname, int line);

void tor_tls_log_one_error(tor_tls_t *tls, unsigned long err,
                           int severity, int domain, const char *doing);
#else /* !defined(ENABLE_OPENSSL) */
#define check_no_tls_errors() STMT_NIL
#endif /* defined(ENABLE_OPENSSL) */

int tor_tls_get_my_certs(int server,
                         const struct tor_x509_cert_t **link_cert_out,
                         const struct tor_x509_cert_t **id_cert_out);
crypto_pk_t *tor_tls_get_my_client_auth_key(void);

const char *tor_tls_get_ciphersuite_name(tor_tls_t *tls);

int evaluate_ecgroup_for_tls(const char *ecgroup);

#endif /* !defined(TOR_TORTLS_H) */
