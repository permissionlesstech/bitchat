/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file weakrng.h
 *
 * \brief Header for weakrng.c
 **/

#ifndef TOR_WEAKRNG_H
#define TOR_WEAKRNG_H

#include "lib/cc/torint.h"

/* ===== Insecure rng */
typedef struct tor_weak_rng_t {
  uint32_t state;
} tor_weak_rng_t;

#ifndef COCCI
#define TOR_WEAK_RNG_INIT {383745623}
#endif
#define TOR_WEAK_RANDOM_MAX (INT_MAX)

void tor_init_weak_random(tor_weak_rng_t *weak_rng, unsigned seed);
int32_t tor_weak_random(tor_weak_rng_t *weak_rng);
int32_t tor_weak_random_range(tor_weak_rng_t *rng, int32_t top);
/** Randomly return true according to <b>rng</b> with probability 1 in
 * <b>n</b> */
#define tor_weak_random_one_in_n(rng, n) (0==tor_weak_random_range((rng),(n)))

#endif /* !defined(TOR_WEAKRNG_H) */
