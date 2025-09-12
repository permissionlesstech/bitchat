/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_BLOOMFILT_H
#define TOR_BLOOMFILT_H

/**
 * \file bloomfilt.h
 *
 * \brief Header for bloomfilt.c
 **/

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/container/bitarray.h"

/** A set of elements, implemented as a Bloom filter. */
typedef struct bloomfilt_t bloomfilt_t;

/** How many 64-bit siphash values to extract per item. */
#define BLOOMFILT_N_HASHES 2

/** How much key material do we need to randomize hashes? */
#define BLOOMFILT_KEY_LEN (BLOOMFILT_N_HASHES * 16)

struct sipkey;
typedef uint64_t (*bloomfilt_hash_fn)(const struct sipkey *key,
                                      const void *item);

void bloomfilt_add(bloomfilt_t *set, const void *item);
int bloomfilt_probably_contains(const bloomfilt_t *set, const void *item);

bloomfilt_t *bloomfilt_new(int max_elements,
                           bloomfilt_hash_fn hashfn,
                           const uint8_t *random_key);
void bloomfilt_free_(bloomfilt_t* set);
#define bloomfilt_free(set) FREE_AND_NULL(bloomfilt_t, bloomfilt_free_, (set))

#endif /* !defined(TOR_BLOOMFILT_H) */
