/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/* Implements a minimal interface to counter-mode AES. */

#ifndef TOR_AES_H
#define TOR_AES_H

/**
 * \file aes.h
 * \brief Headers for aes.c
 */

#include "lib/cc/torint.h"
#include "lib/malloc/malloc.h"

typedef struct aes_cnt_cipher_t aes_cnt_cipher_t;

aes_cnt_cipher_t* aes_new_cipher(const uint8_t *key, const uint8_t *iv,
                                 int key_bits);
void aes_cipher_free_(aes_cnt_cipher_t *cipher);
#define aes_cipher_free(cipher) \
  FREE_AND_NULL(aes_cnt_cipher_t, aes_cipher_free_, (cipher))
void aes_crypt_inplace(aes_cnt_cipher_t *cipher, char *data, size_t len);

int evaluate_evp_for_aes(int force_value);
int evaluate_ctr_for_aes(void);

#endif /* !defined(TOR_AES_H) */
