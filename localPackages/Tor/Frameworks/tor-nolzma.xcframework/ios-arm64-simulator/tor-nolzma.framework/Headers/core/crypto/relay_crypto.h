/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file relay.h
 * \brief Header file for relay.c.
 **/

#ifndef TOR_RELAY_CRYPTO_H
#define TOR_RELAY_CRYPTO_H

int relay_crypto_init(relay_crypto_t *crypto,
                      const char *key_data, size_t key_data_len,
                      int reverse, int is_hs_v3);

int relay_decrypt_cell(circuit_t *circ, cell_t *cell,
                       cell_direction_t cell_direction,
                       crypt_path_t **layer_hint, char *recognized);
void relay_encrypt_cell_outbound(cell_t *cell, origin_circuit_t *or_circ,
                            crypt_path_t *layer_hint);
void relay_encrypt_cell_inbound(cell_t *cell, or_circuit_t *or_circ);

void relay_crypto_clear(relay_crypto_t *crypto);

void relay_crypto_assert_ok(const relay_crypto_t *crypto);

uint8_t *relay_crypto_get_sendme_digest(relay_crypto_t *crypto);

void relay_crypto_record_sendme_digest(relay_crypto_t *crypto,
                                       bool is_foward_digest);

void
relay_crypt_one_payload(crypto_cipher_t *cipher, uint8_t *in);

void
relay_set_digest(crypto_digest_t *digest, cell_t *cell);

#endif /* !defined(TOR_RELAY_CRYPTO_H) */

