/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file hs_ntor.h
 * @brief Header for hs_ntor.c
 **/

#ifndef TOR_HS_NTOR_H
#define TOR_HS_NTOR_H

#include "core/or/or.h"
struct ed25519_public_key_t;
struct curve25519_public_key_t;
struct curve25519_keypair_t;

/* Output length of KDF for key expansion */
#define HS_NTOR_KEY_EXPANSION_KDF_OUT_LEN \
  (DIGEST256_LEN*2 + CIPHER256_KEY_LEN*2)

/* Key material needed to encode/decode INTRODUCE1 cells */
typedef struct hs_ntor_intro_cell_keys_t {
  /* Key used for encryption of encrypted INTRODUCE1 blob */
  uint8_t enc_key[CIPHER256_KEY_LEN];
  /* MAC key used to protect encrypted INTRODUCE1 blob */
  uint8_t mac_key[DIGEST256_LEN];
} hs_ntor_intro_cell_keys_t;

/* Key material needed to encode/decode RENDEZVOUS1 cells */
typedef struct hs_ntor_rend_cell_keys_t {
  /* This is the MAC of the HANDSHAKE_INFO field */
  uint8_t rend_cell_auth_mac[DIGEST256_LEN];
  /* This is the key seed used to derive further rendezvous crypto keys as
   * detailed in section 4.2.1 of rend-spec-ng.txt. */
  uint8_t ntor_key_seed[DIGEST256_LEN];
} hs_ntor_rend_cell_keys_t;

#define SUBCRED_LEN DIGEST256_LEN

/**
 * A 'subcredential' used to prove knowledge of a hidden service.
 **/
typedef struct hs_subcredential_t {
  uint8_t subcred[SUBCRED_LEN];
} hs_subcredential_t;

int hs_ntor_client_get_introduce1_keys(
              const struct ed25519_public_key_t *intro_auth_pubkey,
              const struct curve25519_public_key_t *intro_enc_pubkey,
              const struct curve25519_keypair_t *client_ephemeral_enc_keypair,
              const hs_subcredential_t *subcredential,
              hs_ntor_intro_cell_keys_t *hs_ntor_intro_cell_keys_out);

int hs_ntor_client_get_rendezvous1_keys(
          const struct ed25519_public_key_t *intro_auth_pubkey,
          const struct curve25519_keypair_t *client_ephemeral_enc_keypair,
          const struct curve25519_public_key_t *intro_enc_pubkey,
          const struct curve25519_public_key_t *service_ephemeral_rend_pubkey,
          hs_ntor_rend_cell_keys_t *hs_ntor_rend_cell_keys_out);

int hs_ntor_service_get_introduce1_keys_multi(
            const struct ed25519_public_key_t *intro_auth_pubkey,
            const struct curve25519_keypair_t *intro_enc_keypair,
            const struct curve25519_public_key_t *client_ephemeral_enc_pubkey,
            size_t n_subcredentials,
            const hs_subcredential_t *subcredentials,
            hs_ntor_intro_cell_keys_t *hs_ntor_intro_cell_keys_out);

int hs_ntor_service_get_introduce1_keys(
            const struct ed25519_public_key_t *intro_auth_pubkey,
            const struct curve25519_keypair_t *intro_enc_keypair,
            const struct curve25519_public_key_t *client_ephemeral_enc_pubkey,
            const hs_subcredential_t *subcredential,
            hs_ntor_intro_cell_keys_t *hs_ntor_intro_cell_keys_out);

int hs_ntor_service_get_rendezvous1_keys(
            const struct ed25519_public_key_t *intro_auth_pubkey,
            const struct curve25519_keypair_t *intro_enc_keypair,
            const struct curve25519_keypair_t *service_ephemeral_rend_keypair,
            const struct curve25519_public_key_t *client_ephemeral_enc_pubkey,
            hs_ntor_rend_cell_keys_t *hs_ntor_rend_cell_keys_out);

int hs_ntor_circuit_key_expansion(const uint8_t *ntor_key_seed,
                                  size_t seed_len,
                                  uint8_t *keys_out, size_t keys_out_len);

int hs_ntor_client_rendezvous2_mac_is_good(
                        const hs_ntor_rend_cell_keys_t *hs_ntor_rend_cell_keys,
                        const uint8_t *rcvd_mac);

#endif /* !defined(TOR_HS_NTOR_H) */
