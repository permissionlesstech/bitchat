/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file circuitbuild_relay.h
 * @brief Header for feature/relay/circuitbuild_relay.c
 **/

#ifndef TOR_FEATURE_RELAY_CIRCUITBUILD_RELAY_H
#define TOR_FEATURE_RELAY_CIRCUITBUILD_RELAY_H

#include "lib/cc/torint.h"
#include "lib/log/log.h"

#include "app/config/config.h"

struct cell_t;
struct created_cell_t;

struct circuit_t;
struct or_circuit_t;
struct extend_cell_t;

/* Log a protocol warning about getting an extend cell on a client. */
static inline void
circuitbuild_warn_client_extend(void)
{
  log_fn(LOG_PROTOCOL_WARN, LD_PROTOCOL,
         "Got an extend cell, but running as a client. Closing.");
}

#ifdef HAVE_MODULE_RELAY

int circuit_extend(struct cell_t *cell, struct circuit_t *circ);

int onionskin_answer(struct or_circuit_t *circ,
                     const struct created_cell_t *created_cell,
                     const char *keys, size_t keys_len,
                     const uint8_t *rend_circ_nonce);

#else /* !defined(HAVE_MODULE_RELAY) */

static inline int
circuit_extend(struct cell_t *cell, struct circuit_t *circ)
{
  (void)cell;
  (void)circ;
  circuitbuild_warn_client_extend();
  return -1;
}

static inline int
onionskin_answer(struct or_circuit_t *circ,
                 const struct created_cell_t *created_cell,
                 const char *keys, size_t keys_len,
                 const uint8_t *rend_circ_nonce)
{
  (void)circ;
  (void)created_cell;
  (void)keys;
  (void)keys_len;
  (void)rend_circ_nonce;
  tor_assert_nonfatal_unreached();
  return -1;
}

#endif /* defined(HAVE_MODULE_RELAY) */

#ifdef TOR_UNIT_TESTS

STATIC int circuit_extend_state_valid_helper(const struct circuit_t *circ);
STATIC int circuit_extend_add_ed25519_helper(struct extend_cell_t *ec);
STATIC int circuit_extend_add_ipv4_helper(struct extend_cell_t *ec);
STATIC int circuit_extend_add_ipv6_helper(struct extend_cell_t *ec);
STATIC int circuit_extend_lspec_valid_helper(const struct extend_cell_t *ec,
                                             const struct circuit_t *circ);
STATIC const tor_addr_port_t * circuit_choose_ip_ap_for_extend(
                                             const tor_addr_port_t *ipv4_ap,
                                             const tor_addr_port_t *ipv6_ap);
STATIC void circuit_open_connection_for_extend(const struct extend_cell_t *ec,
                                               struct circuit_t *circ,
                                               int should_launch);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TOR_FEATURE_RELAY_CIRCUITBUILD_RELAY_H) */
