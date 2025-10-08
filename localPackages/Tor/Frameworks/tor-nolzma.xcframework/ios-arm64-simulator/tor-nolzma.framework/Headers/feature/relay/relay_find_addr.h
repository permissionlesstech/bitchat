/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file relay_find_addr.h
 * \brief Header file for relay_find_addr.c.
 **/

#ifndef TOR_RELAY_FIND_ADDR_H
#define TOR_RELAY_FIND_ADDR_H

typedef enum {
  RELAY_FIND_ADDR_NO_FLAG    = (1U << 0),
  RELAY_FIND_ADDR_CACHE_ONLY = (1U << 1),
} relay_find_addr_flags_t;

void relay_address_new_suggestion(const tor_addr_t *suggested_addr,
                                  const tor_addr_t *peer_addr,
                                  const char *identity_digest);

MOCK_DECL(bool, relay_find_addr_to_publish,
          (const or_options_t *options, int family, int flags,
           tor_addr_t *addr_out));

void relay_addr_learn_from_dirauth(void);

#ifdef RELAY_FIND_ADDR_PRIVATE

#endif /* RELAY_FIND_ADDR_PRIVATE */

#endif /* !defined(TOR_RELAY_FIND_ADDR_H) */

