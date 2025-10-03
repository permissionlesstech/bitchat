/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file digestset.h
 * \brief Types to handle sets of digests, based on bloom filters.
 **/

#ifndef TOR_DIGESTSET_H
#define TOR_DIGESTSET_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/container/bloomfilt.h"

/**
 * An digestset_t represents a set of 20-byte digest values. The
 * implementation is probabilistic: false negatives cannot occur but false
 * positives are possible.
 */
typedef struct bloomfilt_t digestset_t;

digestset_t *digestset_new(int max_addresses_guess);
#define digestset_free(set) bloomfilt_free(set)
void digestset_add(digestset_t *set, const char *addr);
int digestset_probably_contains(const digestset_t *set,
                                const char *addr);

#endif /* !defined(TOR_DIGESTSET_H) */
