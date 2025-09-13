/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_ident.h
 * \brief Header file containing circuit and connection identifier data for
 *        the whole HS subsystem.
 *
 * \details
 * This interface is used to uniquely identify a hidden service on a circuit
 * or connection using the service identity public key. Once the circuit or
 * connection subsystem calls in the hidden service one, we use those
 * identifiers to lookup the corresponding objects like service, intro point
 * and descriptor.
 *
 * Furthermore, the circuit identifier holds cryptographic material needed for
 * the e2e encryption on the rendezvous circuit which is set once the
 * rendezvous circuit has opened and ready to be used.
 **/

#ifndef TOR_HS_IDENT_H
#define TOR_HS_IDENT_H

#include "lib/crypt_ops/crypto_ed25519.h"

#include "feature/hs/hs_common.h"

/** Length of the rendezvous cookie that is used to connect circuits at the
 * rendezvous point. */
#define HS_REND_COOKIE_LEN DIGEST_LEN

/** Type of circuit an hs_ident_t object is associated with. */
typedef enum {
  HS_IDENT_CIRCUIT_INTRO      = 1,
  HS_IDENT_CIRCUIT_RENDEZVOUS = 2,
} hs_ident_circuit_type_t;

/** Client and service side circuit identifier that is used for hidden service
 * circuit establishment. Not all fields contain data, it depends on the
 * circuit purpose. This is attached to an origin_circuit_t. All fields are
 * used by both client and service. */
typedef struct hs_ident_circuit_t {
  /** (All circuit) The public key used to uniquely identify the service. It is
   * the one found in the onion address. */
  ed25519_public_key_t identity_pk;

  /** (All circuit) Introduction point authentication key. It's also needed on
   * the rendezvous circuit for the ntor handshake. It's used as the unique key
   * of the introduction point so it should not be shared between multiple
   * intro points. */
  ed25519_public_key_t intro_auth_pk;

  /** (Only client rendezvous circuit) Introduction point encryption public
   * key. We keep it in the rendezvous identifier for the ntor handshake. */
  curve25519_public_key_t intro_enc_pk;

  /** (Only rendezvous circuit) Rendezvous cookie sent from the client to the
   * service with an INTRODUCE1 cell and used by the service in an
   * RENDEZVOUS1 cell. */
  uint8_t rendezvous_cookie[HS_REND_COOKIE_LEN];

  /** (Only service rendezvous circuit) The HANDSHAKE_INFO needed in the
   * RENDEZVOUS1 cell of the service. The construction is as follows:
   *
   *      SERVER_PK   [32 bytes]
   *      AUTH_MAC    [32 bytes]
   */
  uint8_t rendezvous_handshake_info[CURVE25519_PUBKEY_LEN + DIGEST256_LEN];

  /** (Only client rendezvous circuit) Client ephemeral keypair needed for the
   * e2e encryption with the service. */
  curve25519_keypair_t rendezvous_client_kp;

  /** (Only rendezvous circuit) The NTOR_KEY_SEED needed for key derivation for
   * the e2e encryption with the client on the circuit. */
  uint8_t rendezvous_ntor_key_seed[DIGEST256_LEN];

  /** (Only rendezvous circuit) Number of streams associated with this
   * rendezvous circuit. We track this because there is a check on a maximum
   * value. */
  uint64_t num_rdv_streams;
} hs_ident_circuit_t;

/** Client and service side directory connection identifier used for a
 * directory connection to identify which service is being queried. This is
 * attached to a dir_connection_t. */
typedef struct hs_ident_dir_conn_t {
  /** The public key used to uniquely identify the service. It is the one found
   * in the onion address. */
  ed25519_public_key_t identity_pk;

  /** The blinded public key used to uniquely identify the descriptor that this
   * directory connection identifier is for. Only used by the service-side code
   * to fine control descriptor uploads. */
  ed25519_public_key_t blinded_pk;

  /* XXX: Client authorization. */
} hs_ident_dir_conn_t;

/** Client and service side edge connection identifier used for an edge
 * connection to identify which service is being queried. This is attached to
 * a edge_connection_t. */
typedef struct hs_ident_edge_conn_t {
  /** The public key used to uniquely identify the service. It is the one found
   * in the onion address. */
  ed25519_public_key_t identity_pk;

  /** The original virtual port that was used by the client to access the onion
   * service, regardless of the internal port forwarding that might have
   * happened on the service-side. */
  uint16_t orig_virtual_port;
  /* XXX: Client authorization. */
} hs_ident_edge_conn_t;

/* Circuit identifier API. */
hs_ident_circuit_t *hs_ident_circuit_new(
                             const ed25519_public_key_t *identity_pk);
void hs_ident_circuit_free_(hs_ident_circuit_t *ident);
#define hs_ident_circuit_free(id) \
  FREE_AND_NULL(hs_ident_circuit_t, hs_ident_circuit_free_, (id))
hs_ident_circuit_t *hs_ident_circuit_dup(const hs_ident_circuit_t *src);

/* Directory connection identifier API. */
hs_ident_dir_conn_t *hs_ident_dir_conn_dup(const hs_ident_dir_conn_t *src);
void hs_ident_dir_conn_free_(hs_ident_dir_conn_t *ident);
#define hs_ident_dir_conn_free(id) \
  FREE_AND_NULL(hs_ident_dir_conn_t, hs_ident_dir_conn_free_, (id))
void hs_ident_dir_conn_init(const ed25519_public_key_t *identity_pk,
                            const ed25519_public_key_t *blinded_pk,
                            hs_ident_dir_conn_t *ident);
hs_ident_dir_conn_t *hs_ident_server_dir_conn_new(
                              const ed25519_public_key_t *blinded_pk);

/* Edge connection identifier API. */
hs_ident_edge_conn_t *hs_ident_edge_conn_new(
                                    const ed25519_public_key_t *identity_pk);
void hs_ident_edge_conn_free_(hs_ident_edge_conn_t *ident);
#define hs_ident_edge_conn_free(id) \
  FREE_AND_NULL(hs_ident_edge_conn_t, hs_ident_edge_conn_free_, (id))

/* Validators */
int hs_ident_intro_circ_is_valid(const hs_ident_circuit_t *ident);

#endif /* !defined(TOR_HS_IDENT_H) */
