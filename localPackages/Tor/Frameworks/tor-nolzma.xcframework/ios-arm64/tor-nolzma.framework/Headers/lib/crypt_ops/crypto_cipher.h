/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_cipher.h
 *
 * \brief Headers for crypto_cipher.c
 **/

#ifndef TOR_CRYPTO_CIPHER_H
#define TOR_CRYPTO_CIPHER_H

#include "orconfig.h"

#include <stdio.h>
#include "lib/cc/torint.h"

/** Length of our symmetric cipher's keys of 128-bit. */
#define CIPHER_KEY_LEN 16
/** Length of our symmetric cipher's IV of 128-bit. */
#define CIPHER_IV_LEN 16
/** Length of our symmetric cipher's keys of 256-bit. */
#define CIPHER256_KEY_LEN 32

typedef struct aes_cnt_cipher_t crypto_cipher_t;

/* environment setup */
crypto_cipher_t *crypto_cipher_new(const char *key);
crypto_cipher_t *crypto_cipher_new_with_bits(const char *key, int bits);
crypto_cipher_t *crypto_cipher_new_with_iv(const char *key, const char *iv);
crypto_cipher_t *crypto_cipher_new_with_iv_and_bits(const uint8_t *key,
                                                    const uint8_t *iv,
                                                    int bits);
void crypto_cipher_free_(crypto_cipher_t *env);
#define crypto_cipher_free(c) \
  FREE_AND_NULL(crypto_cipher_t, crypto_cipher_free_, (c))

/* symmetric crypto */
const char *crypto_cipher_get_key(crypto_cipher_t *env);

int crypto_cipher_encrypt(crypto_cipher_t *env, char *to,
                          const char *from, size_t fromlen);
int crypto_cipher_decrypt(crypto_cipher_t *env, char *to,
                          const char *from, size_t fromlen);
void crypto_cipher_crypt_inplace(crypto_cipher_t *env, char *d, size_t len);

int crypto_cipher_encrypt_with_iv(const char *key,
                                  char *to, size_t tolen,
                                  const char *from, size_t fromlen);
int crypto_cipher_decrypt_with_iv(const char *key,
                                  char *to, size_t tolen,
                                  const char *from, size_t fromlen);

#endif /* !defined(TOR_CRYPTO_CIPHER_H) */
