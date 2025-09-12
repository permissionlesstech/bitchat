/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_dh.h
 *
 * \brief Headers for crypto_dh.c
 **/

#ifndef TOR_CRYPTO_DH_H
#define TOR_CRYPTO_DH_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/defs/dh_sizes.h"

typedef struct crypto_dh_t crypto_dh_t;

extern const unsigned DH_GENERATOR;
extern const char TLS_DH_PRIME[];
extern const char OAKLEY_PRIME_2[];

/* Key negotiation */
#define DH_TYPE_CIRCUIT 1
#define DH_TYPE_REND 2
#define DH_TYPE_TLS 3
void crypto_dh_init(void);
crypto_dh_t *crypto_dh_new(int dh_type);
crypto_dh_t *crypto_dh_dup(const crypto_dh_t *dh);
int crypto_dh_get_bytes(crypto_dh_t *dh);
int crypto_dh_generate_public(crypto_dh_t *dh);
int crypto_dh_get_public(crypto_dh_t *dh, char *pubkey_out,
                         size_t pubkey_out_len);
ssize_t crypto_dh_compute_secret(int severity, crypto_dh_t *dh,
                             const char *pubkey, size_t pubkey_len,
                             char *secret_out, size_t secret_out_len);
void crypto_dh_free_(crypto_dh_t *dh);
#define crypto_dh_free(dh) FREE_AND_NULL(crypto_dh_t, crypto_dh_free_, (dh))

ssize_t crypto_dh_handshake(int severity, crypto_dh_t *dh,
                            const char *pubkey, size_t pubkey_len,
                            unsigned char *secret_out,
                            size_t secret_bytes_out);

void crypto_dh_free_all(void);

/* Prototypes for private functions only used by tortls.c, crypto.c, and the
 * unit tests. */
struct dh_st;
struct dh_st *crypto_dh_new_openssl_tls(void);

#ifdef ENABLE_OPENSSL
void crypto_dh_init_openssl(void);
void crypto_dh_free_all_openssl(void);
#endif
#ifdef ENABLE_NSS
void crypto_dh_init_nss(void);
void crypto_dh_free_all_nss(void);
#endif

#endif /* !defined(TOR_CRYPTO_DH_H) */
