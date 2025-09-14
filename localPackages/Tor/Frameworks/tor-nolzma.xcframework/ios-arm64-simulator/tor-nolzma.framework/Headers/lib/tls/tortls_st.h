/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_TORTLS_ST_H
#define TOR_TORTLS_ST_H

/**
 * @file tortls_st.h
 * @brief Structure declarations for internal TLS types.
 *
 * These should generally be treated as opaque outside of the
 * lib/tls module.
 **/

#include "lib/net/socket.h"

#define TOR_TLS_MAGIC 0x71571571

typedef enum {
    TOR_TLS_ST_HANDSHAKE, TOR_TLS_ST_OPEN, TOR_TLS_ST_GOTCLOSE,
    TOR_TLS_ST_SENTCLOSE, TOR_TLS_ST_CLOSED, TOR_TLS_ST_RENEGOTIATE,
    TOR_TLS_ST_BUFFEREVENT
} tor_tls_state_t;
#define tor_tls_state_bitfield_t ENUM_BF(tor_tls_state_t)

struct tor_tls_context_t {
  int refcnt;
  tor_tls_context_impl_t *ctx;
  struct tor_x509_cert_t *my_link_cert;
  struct tor_x509_cert_t *my_id_cert;
  struct tor_x509_cert_t *my_auth_cert;
  crypto_pk_t *link_key;
  crypto_pk_t *auth_key;
};

/** Holds a SSL object and its associated data.  Members are only
 * accessed from within tortls.c.
 */
struct tor_tls_t {
  uint32_t magic;
  tor_tls_context_t *context; /** A link to the context object for this tls. */
  tor_tls_impl_t *ssl; /**< An OpenSSL SSL object or NSS PRFileDesc. */
  tor_socket_t socket; /**< The underlying file descriptor for this TLS
                        * connection. */
  char *address; /**< An address to log when describing this connection. */
  tor_tls_state_bitfield_t state : 3; /**< The current SSL state,
                                       * depending on which operations
                                       * have completed successfully. */
  unsigned int isServer:1; /**< True iff this is a server-side connection */
  unsigned int wasV2Handshake:1; /**< True iff the original handshake for
                                  * this connection used the updated version
                                  * of the connection protocol (client sends
                                  * different cipher list, server sends only
                                  * one certificate). */
  /** True iff we should call negotiated_callback when we're done reading. */
  unsigned int got_renegotiate:1;
#ifdef ENABLE_OPENSSL
  /** Return value from tor_tls_classify_client_ciphers, or 0 if we haven't
   * called that function yet. */
  int8_t client_cipher_list_type;
  size_t wantwrite_n; /**< 0 normally, >0 if we returned wantwrite last
                       * time. */
  /** Last values retrieved from BIO_number_read()/write(); see
   * tor_tls_get_n_raw_bytes() for usage.
   */
  unsigned long last_write_count;
  unsigned long last_read_count;
  /** Most recent error value from ERR_get_error(). */
  unsigned long last_error;
  /** If set, a callback to invoke whenever the client tries to renegotiate
   * the handshake. */
  void (*negotiated_callback)(tor_tls_t *tls, void *arg);
  /** Argument to pass to negotiated_callback. */
  void *callback_arg;
#endif /* defined(ENABLE_OPENSSL) */
#ifdef ENABLE_NSS
  /** Last values retried from tor_get_prfiledesc_byte_counts(). */
  uint64_t last_write_count;
  uint64_t last_read_count;
  long last_error;
#endif /* defined(ENABLE_NSS) */
};

#endif /* !defined(TOR_TORTLS_ST_H) */
