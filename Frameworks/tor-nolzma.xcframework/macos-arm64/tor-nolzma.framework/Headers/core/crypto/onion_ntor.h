/* Copyright (c) 2012-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file onion_ntor.h
 * @brief Header for onion_ntor.c
 **/

#ifndef TOR_ONION_NTOR_H
#define TOR_ONION_NTOR_H

#include "lib/cc/torint.h"

struct di_digest256_map_t;
struct curve25519_public_key_t;
struct curve25519_keypair_t;

/** State to be maintained by a client between sending an ntor onionskin
 * and receiving a reply. */
typedef struct ntor_handshake_state_t ntor_handshake_state_t;

/** Length of an ntor onionskin, as sent from the client to server. */
#define NTOR_ONIONSKIN_LEN 84
/** Length of an ntor reply, as sent from server to client. */
#define NTOR_REPLY_LEN 64

void ntor_handshake_state_free_(ntor_handshake_state_t *state);
#define ntor_handshake_state_free(state) \
  FREE_AND_NULL(ntor_handshake_state_t, ntor_handshake_state_free_, (state))

int onion_skin_ntor_create(const uint8_t *router_id,
                           const struct curve25519_public_key_t *router_key,
                           ntor_handshake_state_t **handshake_state_out,
                           uint8_t *onion_skin_out);

int onion_skin_ntor_server_handshake(const uint8_t *onion_skin,
                           const struct di_digest256_map_t *private_keys,
                           const struct curve25519_keypair_t *junk_keypair,
                           const uint8_t *my_node_id,
                           uint8_t *handshake_reply_out,
                           uint8_t *key_out,
                           size_t key_out_len);

int onion_skin_ntor_client_handshake(
                             const ntor_handshake_state_t *handshake_state,
                             const uint8_t *handshake_reply,
                             uint8_t *key_out,
                             size_t key_out_len,
                             const char **msg_out);

#ifdef ONION_NTOR_PRIVATE
#include "lib/crypt_ops/crypto_curve25519.h"

/** Storage held by a client while waiting for an ntor reply from a server. */
struct ntor_handshake_state_t {
  /** Identity digest of the router we're talking to. */
  uint8_t router_id[DIGEST_LEN];
  /** Onion key of the router we're talking to. */
  curve25519_public_key_t pubkey_B;

  /**
   * Short-lived keypair for use with this handshake.
   * @{ */
  curve25519_secret_key_t seckey_x;
  curve25519_public_key_t pubkey_X;
  /** @} */
};
#endif /* defined(ONION_NTOR_PRIVATE) */

#endif /* !defined(TOR_ONION_NTOR_H) */
