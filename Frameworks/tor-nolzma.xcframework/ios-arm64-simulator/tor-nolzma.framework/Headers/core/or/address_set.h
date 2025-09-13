/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file address_set.h
 * \brief Types to handle sets of addresses.
 **/

#ifndef TOR_ADDRESS_SET_H
#define TOR_ADDRESS_SET_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/container/bloomfilt.h"

struct tor_addr_t;

/**
 * An address_set_t represents a set of tor_addr_t values. The implementation
 * is probabilistic: false negatives cannot occur but false positives are
 * possible.
 */
typedef struct bloomfilt_t address_set_t;

address_set_t *address_set_new(int max_addresses_guess);
#define address_set_free(set) bloomfilt_free(set)
void address_set_add(address_set_t *set, const struct tor_addr_t *addr);
void address_set_add_ipv4h(address_set_t *set, uint32_t addr);
int address_set_probably_contains(const address_set_t *set,
                                  const struct tor_addr_t *addr);

#endif /* !defined(TOR_ADDRESS_SET_H) */
