/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_s2k.h
 *
 * \brief Header for crypto_s2k.c
 **/

#ifndef TOR_CRYPTO_S2K_H_INCLUDED
#define TOR_CRYPTO_S2K_H_INCLUDED

#include <stdio.h>
#include "lib/cc/torint.h"

/** Length of RFC2440-style S2K specifier: the first 8 bytes are a salt, the
 * 9th describes how much iteration to do. */
#define S2K_RFC2440_SPECIFIER_LEN 9
void secret_to_key_rfc2440(
                   char *key_out, size_t key_out_len, const char *secret,
                   size_t secret_len, const char *s2k_specifier);

/** Flag for secret-to-key function: do not use scrypt. */
#define S2K_FLAG_NO_SCRYPT  (1u<<0)
/** Flag for secret-to-key functions: if using a memory-tuned s2k function,
 * assume that we have limited memory. */
#define S2K_FLAG_LOW_MEM    (1u<<1)
/** Flag for secret-to-key functions: force use of pbkdf2.  Without this, we
 * default to scrypt, then RFC2440. */
#define S2K_FLAG_USE_PBKDF2 (1u<<2)

/** Maximum possible output length from secret_to_key_new. */
#define S2K_MAXLEN 64

/** Error code from secret-to-key functions: all is well */
#define S2K_OKAY 0
/** Error code from secret-to-key functions: generic failure */
#define S2K_FAILED -1
/** Error code from secret-to-key functions: provided secret didn't match */
#define S2K_BAD_SECRET -2
/** Error code from secret-to-key functions: didn't recognize the algorithm */
#define S2K_BAD_ALGORITHM -3
/** Error code from secret-to-key functions: specifier wasn't valid */
#define S2K_BAD_PARAMS -4
/** Error code from secret-to-key functions: compiled without scrypt */
#define S2K_NO_SCRYPT_SUPPORT -5
/** Error code from secret-to-key functions: not enough space to write output.
 */
#define S2K_TRUNCATED -6
/** Error code from secret-to-key functions: Wrong length for specifier. */
#define S2K_BAD_LEN -7

int secret_to_key_new(uint8_t *buf,
                      size_t buf_len,
                      size_t *len_out,
                      const char *secret, size_t secret_len,
                      unsigned flags);

int secret_to_key_make_specifier(uint8_t *buf, size_t buf_len, unsigned flags);

int secret_to_key_check(const uint8_t *spec_and_key, size_t spec_and_key_len,
                          const char *secret, size_t secret_len);

int secret_to_key_derivekey(uint8_t *key_out, size_t key_out_len,
                            const uint8_t *spec, size_t spec_len,
                            const char *secret, size_t secret_len);

#ifdef CRYPTO_S2K_PRIVATE
STATIC int secret_to_key_compute_key(uint8_t *key_out, size_t key_out_len,
                                     const uint8_t *spec, size_t spec_len,
                                     const char *secret, size_t secret_len,
                                     int type);
#endif /* defined(CRYPTO_S2K_PRIVATE) */

#endif /* !defined(TOR_CRYPTO_S2K_H_INCLUDED) */
