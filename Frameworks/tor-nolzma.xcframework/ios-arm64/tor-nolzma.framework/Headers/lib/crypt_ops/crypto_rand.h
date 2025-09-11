/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file crypto_rand.h
 *
 * \brief Common functions for using (pseudo-)random number generators.
 **/

#ifndef TOR_CRYPTO_RAND_H
#define TOR_CRYPTO_RAND_H

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"
#include "lib/malloc/malloc.h"

/* random numbers */
int crypto_seed_rng(void) ATTR_WUR;
MOCK_DECL(void,crypto_rand,(char *to, size_t n));
void crypto_rand_unmocked(char *to, size_t n);
void crypto_strongest_rand(uint8_t *out, size_t out_len);
MOCK_DECL(void,crypto_strongest_rand_,(uint8_t *out, size_t out_len));
int crypto_rand_int(unsigned int max);
unsigned crypto_rand_uint(unsigned limit);
int crypto_rand_int_range(unsigned int min, unsigned int max);
uint64_t crypto_rand_uint64_range(uint64_t min, uint64_t max);
time_t crypto_rand_time_range(time_t min, time_t max);
uint32_t crypto_rand_u32(void);
uint64_t crypto_rand_uint64(uint64_t max);
double crypto_rand_double(void);
struct tor_weak_rng_t;
void crypto_seed_weak_rng(struct tor_weak_rng_t *rng);

char *crypto_random_hostname(int min_rand_len, int max_rand_len,
                             const char *prefix, const char *suffix);

struct smartlist_t;
void *smartlist_choose(const struct smartlist_t *sl);
void smartlist_shuffle(struct smartlist_t *sl);
int crypto_force_rand_ssleay(void);

/**
 * A fast PRNG, for use when the PRNG provided by our crypto library isn't
 * fast enough.  This one _should_ be cryptographically strong, but
 * has seen less auditing than the PRNGs in OpenSSL and NSS.  Use with
 * caution.
 *
 * Note that this object is NOT thread-safe.  If you need a thread-safe
 * prng, use crypto_rand(), or wrap this in a mutex.
 **/
typedef struct crypto_fast_rng_t crypto_fast_rng_t;
/**
 * Number of bytes used to seed a crypto_rand_fast_t.
 **/
crypto_fast_rng_t *crypto_fast_rng_new(void);
#define CRYPTO_FAST_RNG_SEED_LEN 48
crypto_fast_rng_t *crypto_fast_rng_new_from_seed(const uint8_t *seed);
void crypto_fast_rng_getbytes(crypto_fast_rng_t *rng, uint8_t *out, size_t n);
void crypto_fast_rng_free_(crypto_fast_rng_t *);
#define crypto_fast_rng_free(c)                                 \
  FREE_AND_NULL(crypto_fast_rng_t, crypto_fast_rng_free_, (c))

unsigned crypto_fast_rng_get_uint(crypto_fast_rng_t *rng, unsigned limit);
uint64_t crypto_fast_rng_get_uint64(crypto_fast_rng_t *rng, uint64_t limit);
uint32_t crypto_fast_rng_get_u32(crypto_fast_rng_t *rng);
uint64_t crypto_fast_rng_uint64_range(crypto_fast_rng_t *rng,
                                      uint64_t min, uint64_t max);
double crypto_fast_rng_get_double(crypto_fast_rng_t *rng);

/**
 * Using the fast_rng <b>rng</b>, yield true with probability
 * 1/<b>n</b>. Otherwise yield false.
 *
 * <b>n</b> must not be zero.
 **/
#define crypto_fast_rng_one_in_n(rng, n)        \
  (0 == (crypto_fast_rng_get_uint((rng), (n))))

crypto_fast_rng_t *get_thread_fast_rng(void);

#ifdef CRYPTO_PRIVATE
/* These are only used from crypto_init.c */
void destroy_thread_fast_rng(void);
void crypto_rand_fast_init(void);
void crypto_rand_fast_shutdown(void);
#endif /* defined(CRYPTO_PRIVATE) */

#if defined(TOR_UNIT_TESTS)
/* Used for white-box testing */
size_t crypto_fast_rng_get_bytes_used_per_stream(void);
/* For deterministic prng implementations */
void crypto_fast_rng_disable_reseed(crypto_fast_rng_t *rng);
/* To override the prng for testing. */
crypto_fast_rng_t *crypto_replace_thread_fast_rng(crypto_fast_rng_t *rng);
#endif /* defined(TOR_UNIT_TESTS) */

#ifdef CRYPTO_RAND_PRIVATE

STATIC int crypto_strongest_rand_raw(uint8_t *out, size_t out_len);

#ifdef TOR_UNIT_TESTS
extern int break_strongest_rng_syscall;
extern int break_strongest_rng_fallback;
#endif
#endif /* defined(CRYPTO_RAND_PRIVATE) */

#endif /* !defined(TOR_CRYPTO_RAND_H) */
