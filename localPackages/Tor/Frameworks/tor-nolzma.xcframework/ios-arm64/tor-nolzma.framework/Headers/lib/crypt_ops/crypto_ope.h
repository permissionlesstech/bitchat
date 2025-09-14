/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file crypto_ope.h
 * @brief header for crypto_ope.c
 **/

#ifndef CRYPTO_OPE_H
#define CRYPTO_OPE_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/crypt_ops/crypto_ope.h"
#include "lib/testsupport/testsupport.h"

/** Length of OPE key, in bytes. */
#define OPE_KEY_LEN 32

/** Largest value that can be passed to crypto_ope_encrypt().
 *
 *  Expressed as 2^18 because the OPE system prefers powers of two.
 *
 *  The current max value stands for about 70 hours. The rationale here is as
 *  follows: The rev counter is the time of seconds since the start of an SRV
 *  period. SRVs are useful for about 48 hours (that's how long they stick
 *  around on the consensus). Let's also add 12 hours of drift for clock skewed
 *  services that might be using an old consensus and we arrive to 60
 *  hours. The max value should be beyond that.
 */
#define OPE_INPUT_MAX (1<<18)

#define CRYPTO_OPE_ERROR UINT64_MAX

typedef struct crypto_ope_t crypto_ope_t;

crypto_ope_t *crypto_ope_new(const uint8_t *key);
void crypto_ope_free_(crypto_ope_t *ope);
#define crypto_ope_free(ope) \
  FREE_AND_NULL(crypto_ope_t, crypto_ope_free_, (ope))

uint64_t crypto_ope_encrypt(const crypto_ope_t *ope, int plaintext);

#ifdef CRYPTO_OPE_PRIVATE
struct aes_cnt_cipher_t;
STATIC struct aes_cnt_cipher_t *ope_get_cipher(const crypto_ope_t *ope,
                                              uint32_t initial_idx);
STATIC uint64_t sum_values_from_cipher(struct aes_cnt_cipher_t *c, size_t n);
#endif /* defined(CRYPTO_OPE_PRIVATE) */

#endif /* !defined(CRYPTO_OPE_H) */
