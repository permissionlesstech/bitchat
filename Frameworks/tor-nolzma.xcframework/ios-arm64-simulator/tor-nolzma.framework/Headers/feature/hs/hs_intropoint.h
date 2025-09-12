/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_intropoint.h
 * \brief Header file for hs_intropoint.c.
 **/

#ifndef TOR_HS_INTRO_H
#define TOR_HS_INTRO_H

#include "lib/crypt_ops/crypto_curve25519.h"
#include "feature/nodelist/torcert.h"

/** Object containing introduction point common data between the service and
 * the client side. */
typedef struct hs_intropoint_t {
  /** Does this intro point only supports legacy ID ?. */
  unsigned int is_only_legacy : 1;

  /** Authentication key certificate from the descriptor. */
  tor_cert_t *auth_key_cert;
  /** A list of link specifier. */
  smartlist_t *link_specifiers;
} hs_intropoint_t;

int hs_intro_received_establish_intro(or_circuit_t *circ,
                                      const uint8_t *request,
                                      size_t request_len);
int hs_intro_received_introduce1(or_circuit_t *circ, const uint8_t *request,
                                 size_t request_len);

MOCK_DECL(int, hs_intro_send_intro_established_cell,(or_circuit_t *circ));

/* also used by rendservice.c */
int hs_intro_circuit_is_suitable_for_establish_intro(const or_circuit_t *circ);

hs_intropoint_t *hs_intro_new(void);
void hs_intropoint_clear(hs_intropoint_t *ip);

#ifdef HS_INTROPOINT_PRIVATE

#include "trunnel/hs/cell_establish_intro.h"
#include "trunnel/hs/cell_introduce1.h"

STATIC int
verify_establish_intro_cell(const trn_cell_establish_intro_t *out,
                            const uint8_t *circuit_key_material,
                            size_t circuit_key_material_len);

STATIC void
get_auth_key_from_cell(ed25519_public_key_t *auth_key_out,
                       unsigned int cell_type, const void *cell);

STATIC int handle_introduce1(or_circuit_t *client_circ,
                             const uint8_t *request, size_t request_len);
STATIC int validate_introduce1_parsed_cell(const trn_cell_introduce1_t *cell);
STATIC int circuit_is_suitable_for_introduce1(const or_circuit_t *circ);
STATIC bool cell_dos_extension_parameters_are_valid(
                                          uint64_t intro2_rate_per_sec,
                                          uint64_t intro2_burst_per_sec);

#endif /* defined(HS_INTROPOINT_PRIVATE) */

#endif /* !defined(TOR_HS_INTRO_H) */
