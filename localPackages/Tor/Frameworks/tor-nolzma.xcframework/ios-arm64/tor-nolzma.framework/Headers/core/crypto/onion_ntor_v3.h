/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file onion_ntor_v3.h
 * @brief Header for core/crypto/onion_ntor_v3.c
 **/

#ifndef TOR_CORE_CRYPTO_ONION_NTOR_V3_H
#define TOR_CORE_CRYPTO_ONION_NTOR_V3_H

#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"
#include "lib/crypt_ops/crypto_cipher.h"
#include "lib/crypt_ops/crypto_curve25519.h"
#include "lib/crypt_ops/crypto_ed25519.h"
#include "lib/malloc/malloc.h"

/**
 * Client-side state held while an ntor v3 handshake is in progress.
 **/
typedef struct ntor3_handshake_state_t ntor3_handshake_state_t;

/**
 * Server-side state held while the relay is handling a client's
 * encapsulated message, before replying to the v3 handshake.
 **/
typedef struct ntor3_server_handshake_state_t ntor3_server_handshake_state_t;

void ntor3_handshake_state_free_(ntor3_handshake_state_t *st);
#define ntor3_handshake_state_free(ptr) \
  FREE_AND_NULL(ntor3_handshake_state_t, ntor3_handshake_state_free_, (ptr))
void ntor3_server_handshake_state_free_(ntor3_server_handshake_state_t *st);
#define ntor3_server_handshake_state_free(ptr) \
  FREE_AND_NULL(ntor3_server_handshake_state_t, \
                ntor3_server_handshake_state_free_, (ptr))

int onion_skin_ntor3_create(const ed25519_public_key_t *relay_id,
                            const curve25519_public_key_t *relay_key,
                            const uint8_t *verification,
                            const size_t verification_len,
                            const uint8_t *message,
                            const size_t message_len,
                            ntor3_handshake_state_t **handshake_state_out,
                            uint8_t **onion_skin_out,
                            size_t *onion_skin_len_out);

int onion_ntor3_client_handshake(
                             const ntor3_handshake_state_t *handshake_state,
                             const uint8_t *handshake_reply,
                             size_t reply_len,
                             const uint8_t *verification,
                             size_t verification_len,
                             uint8_t *keys_out,
                             size_t keys_out_len,
                             uint8_t **message_out,
                             size_t *message_len_out);

struct di_digest256_map_t;
int onion_skin_ntor3_server_handshake_part1(
                const struct di_digest256_map_t *private_keys,
                const curve25519_keypair_t *junk_key,
                const ed25519_public_key_t *my_id,
                const uint8_t *client_handshake,
                size_t client_handshake_len,
                const uint8_t *verification,
                size_t verification_len,
                uint8_t **client_message_out,
                size_t *client_message_len_out,
                ntor3_server_handshake_state_t **state_out);

int onion_skin_ntor3_server_handshake_part2(
                const ntor3_server_handshake_state_t *state,
                const uint8_t *verification,
                size_t verification_len,
                const uint8_t *server_message,
                size_t server_message_len,
                uint8_t **handshake_out,
                size_t *handshake_len_out,
                uint8_t *keys_out,
                size_t keys_out_len);

#ifdef ONION_NTOR_V3_PRIVATE
struct ntor3_handshake_state_t {
  /** Ephemeral (x,X) keypair. */
  curve25519_keypair_t client_keypair;
  /** Relay's ed25519 identity key (ID) */
  ed25519_public_key_t relay_id;
  /** Relay's public key (B) */
  curve25519_public_key_t relay_key;
  /** Shared secret (Bx). */
  uint8_t bx[CURVE25519_OUTPUT_LEN];
  /** MAC of the client's encrypted message data (MAC) */
  uint8_t msg_mac[DIGEST256_LEN];
};

struct ntor3_server_handshake_state_t {
  /** Relay's ed25519 identity key (ID) */
  ed25519_public_key_t my_id;
  /** Relay's public key (B) */
  curve25519_public_key_t my_key;
  /** Client's public ephemeral key (X). */
  curve25519_public_key_t client_key;

  /** Shared secret (Xb) */
  uint8_t xb[CURVE25519_OUTPUT_LEN];
  /** MAC of the client's encrypted message data */
  uint8_t msg_mac[DIGEST256_LEN];
};

STATIC int onion_skin_ntor3_create_nokeygen(
                        const curve25519_keypair_t *client_keypair,
                        const ed25519_public_key_t *relay_id,
                        const curve25519_public_key_t *relay_key,
                        const uint8_t *verification,
                        const size_t verification_len,
                        const uint8_t *message,
                        const size_t message_len,
                        ntor3_handshake_state_t **handshake_state_out,
                        uint8_t **onion_skin_out,
                        size_t *onion_skin_len_out);

STATIC int onion_skin_ntor3_server_handshake_part2_nokeygen(
                const curve25519_keypair_t *relay_keypair_y,
                const ntor3_server_handshake_state_t *state,
                const uint8_t *verification,
                size_t verification_len,
                const uint8_t *server_message,
                size_t server_message_len,
                uint8_t **handshake_out,
                size_t *handshake_len_out,
                uint8_t *keys_out,
                size_t keys_out_len);

#endif

#endif /* !defined(TOR_CORE_CRYPTO_ONION_NTOR_V3_H) */
