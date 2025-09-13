/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_circuitmap.h
 * \brief Header file for hs_circuitmap.c.
 **/

#ifndef TOR_HS_CIRCUITMAP_H
#define TOR_HS_CIRCUITMAP_H

typedef HT_HEAD(hs_circuitmap_ht, circuit_t) hs_circuitmap_ht;

typedef struct hs_token_t hs_token_t;
struct or_circuit_t;
struct origin_circuit_t;
struct ed25519_public_key_t;

/** Public HS circuitmap API: */

/** Public relay-side API: */

struct or_circuit_t *
hs_circuitmap_get_intro_circ_v3_relay_side(const
                                   struct ed25519_public_key_t *auth_key);
struct or_circuit_t *
hs_circuitmap_get_rend_circ_relay_side(const uint8_t *cookie);

void hs_circuitmap_register_rend_circ_relay_side(struct or_circuit_t *circ,
                                                 const uint8_t *cookie);
void hs_circuitmap_register_intro_circ_v3_relay_side(struct or_circuit_t *circ,
                                 const struct ed25519_public_key_t *auth_key);

smartlist_t *hs_circuitmap_get_all_intro_circ_relay_side(void);

/** Public service-side API: */

struct origin_circuit_t *
hs_circuitmap_get_intro_circ_v3_service_side(const
                                     struct ed25519_public_key_t *auth_key);
struct origin_circuit_t *
hs_circuitmap_get_rend_circ_service_side(const uint8_t *cookie);
struct origin_circuit_t *
hs_circuitmap_get_rend_circ_client_side(const uint8_t *cookie);
struct origin_circuit_t *
hs_circuitmap_get_established_rend_circ_client_side(const uint8_t *cookie);

void hs_circuitmap_register_intro_circ_v3_service_side(
                                 struct origin_circuit_t *circ,
                                 const struct ed25519_public_key_t *auth_key);
void hs_circuitmap_register_rend_circ_service_side(
                                        struct origin_circuit_t *circ,
                                        const uint8_t *cookie);
void hs_circuitmap_register_rend_circ_client_side(
                                      struct origin_circuit_t *circ,
                                      const uint8_t *cookie);

void hs_circuitmap_remove_circuit(struct circuit_t *circ);

void hs_circuitmap_init(void);
void hs_circuitmap_free_all(void);

#ifdef HS_CIRCUITMAP_PRIVATE

/** Represents the type of HS token. */
typedef enum {
  /** A rendezvous cookie on a relay (128bit)*/
  HS_TOKEN_REND_RELAY_SIDE,
  /** A v3 introduction point pubkey on a relay (256bit) */
  HS_TOKEN_INTRO_V3_RELAY_SIDE,

  /** A rendezvous cookie on a hidden service (128bit)*/
  HS_TOKEN_REND_SERVICE_SIDE,
  /** A v3 introduction point pubkey on a hidden service (256bit) */
  HS_TOKEN_INTRO_V3_SERVICE_SIDE,

  /** A rendezvous cookie on the client side (128bit) */
  HS_TOKEN_REND_CLIENT_SIDE,
} hs_token_type_t;

/** Represents a token used in the HS protocol. Each such token maps to a
 *  specific introduction or rendezvous circuit. */
struct hs_token_t {
  /* Type of HS token. */
  hs_token_type_t type;

  /* The size of the token (depends on the type). */
  size_t token_len;

  /* The token itself. Memory allocated at runtime. */
  uint8_t *token;
};

#endif /* defined(HS_CIRCUITMAP_PRIVATE) */

#ifdef TOR_UNIT_TESTS

hs_circuitmap_ht *get_hs_circuitmap(void);

#endif /* TOR_UNIT_TESTS */

#endif /* !defined(TOR_HS_CIRCUITMAP_H) */
