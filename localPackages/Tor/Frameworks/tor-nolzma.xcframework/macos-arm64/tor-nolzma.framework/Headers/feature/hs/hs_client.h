/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_client.h
 * \brief Header file containing client data for the HS subsystem.
 **/

#ifndef TOR_HS_CLIENT_H
#define TOR_HS_CLIENT_H

#include "lib/crypt_ops/crypto_ed25519.h"

#include "feature/hs/hs_circuit.h"
#include "feature/hs/hs_descriptor.h"
#include "feature/hs/hs_ident.h"

/** Status code of a descriptor fetch request. */
typedef enum {
  /** Something internally went wrong. */
  HS_CLIENT_FETCH_ERROR        = -1,
  /** The fetch request has been launched successfully. */
  HS_CLIENT_FETCH_LAUNCHED     = 0,
  /** We already have a usable descriptor. No fetch. */
  HS_CLIENT_FETCH_HAVE_DESC    = 1,
  /** No more HSDir available to query. */
  HS_CLIENT_FETCH_NO_HSDIRS    = 2,
  /** The fetch request is not allowed. */
  HS_CLIENT_FETCH_NOT_ALLOWED  = 3,
  /** We are missing information to be able to launch a request. */
  HS_CLIENT_FETCH_MISSING_INFO = 4,
  /** There is a pending fetch for the requested service. */
  HS_CLIENT_FETCH_PENDING      = 5,
} hs_client_fetch_status_t;

/* Status code of client auth credential registration */
typedef enum {
  /* We successfully registered these credentials */
  REGISTER_SUCCESS,
  /* We successfully registered these credentials, but had to replace some
   * existing ones. */
  REGISTER_SUCCESS_ALREADY_EXISTS,
  /* We successfully registered these credentials, and also decrypted a cached
   * descriptor. */
  REGISTER_SUCCESS_AND_DECRYPTED,
  /* We failed to register these credentials, because of a bad HS address. */
  REGISTER_FAIL_BAD_ADDRESS,
  /* We failed to store these credentials in a persistent file on disk. */
  REGISTER_FAIL_PERMANENT_STORAGE,
} hs_client_register_auth_status_t;

/* Status code of client auth credential removal */
typedef enum {
  /* We successfully removed these credentials */
  REMOVAL_SUCCESS,
  /* No need to remove those credentials, because they were not there. */
  REMOVAL_SUCCESS_NOT_FOUND,
  /* We failed to register these credentials, because of a bad HS address. */
  REMOVAL_BAD_ADDRESS,
} hs_client_removal_auth_status_t;

/** Flag to set when a client auth is permanent (saved on disk). */
#define CLIENT_AUTH_FLAG_IS_PERMANENT (1<<0)

/** Client-side configuration of client authorization */
typedef struct hs_client_service_authorization_t {
  /** An curve25519 secret key used to compute decryption keys that
   * allow the client to decrypt the hidden service descriptor. */
  curve25519_secret_key_t enc_seckey;

  /** An onion address that is used to connect to the onion service. */
  char onion_address[HS_SERVICE_ADDR_LEN_BASE32+1];

  /** An client name used to connect to the onion service. */
  char *client_name;

  /* Optional flags for this client. */
  int flags;
} hs_client_service_authorization_t;

const hs_desc_intro_point_t *
find_desc_intro_point_by_ident(const hs_ident_circuit_t *ident,
                               const hs_descriptor_t *desc);

hs_client_register_auth_status_t
hs_client_register_auth_credentials(hs_client_service_authorization_t *creds);

hs_client_removal_auth_status_t
hs_client_remove_auth_credentials(const char *hsaddress);

digest256map_t *get_hs_client_auths_map(void);

#define client_service_authorization_free(auth)                      \
  FREE_AND_NULL(hs_client_service_authorization_t,                   \
                client_service_authorization_free_, (auth))

void
client_service_authorization_free_(hs_client_service_authorization_t *auth);

void hs_client_note_connection_attempt_succeeded(
                                       const edge_connection_t *conn);

void hs_client_launch_v3_desc_fetch(
                               const ed25519_public_key_t *onion_identity_pk,
                               const smartlist_t *hsdirs);

int send_introduce1(origin_circuit_t *intro_circ,
                    origin_circuit_t *rend_circ,
                    const hs_descriptor_t *desc,
                    hs_pow_solution_t *pow_solution,
                    const hs_desc_intro_point_t *ip);

hs_desc_decode_status_t hs_client_decode_descriptor(
                     const char *desc_str,
                     const ed25519_public_key_t *service_identity_pk,
                     hs_descriptor_t **desc);
int hs_client_any_intro_points_usable(const ed25519_public_key_t *service_pk,
                                      const hs_descriptor_t *desc);
int hs_client_refetch_hsdesc(const ed25519_public_key_t *identity_pk);
void hs_client_dir_info_changed(void);

int hs_client_setup_intro_circ_auth_key(origin_circuit_t *circ);

int hs_client_send_introduce1(origin_circuit_t *intro_circ,
                              origin_circuit_t *rend_circ);

void hs_client_circuit_has_opened(origin_circuit_t *circ);
void hs_client_circuit_cleanup_on_close(const circuit_t *circ);
void hs_client_circuit_cleanup_on_free(const circuit_t *circ);

int hs_client_receive_rendezvous_acked(origin_circuit_t *circ,
                                       const uint8_t *payload,
                                       size_t payload_len);
int hs_client_receive_introduce_ack(origin_circuit_t *circ,
                                    const uint8_t *payload,
                                    size_t payload_len);
int hs_client_receive_rendezvous2(origin_circuit_t *circ,
                                  const uint8_t *payload,
                                  size_t payload_len);

void hs_client_dir_fetch_done(dir_connection_t *dir_conn, const char *reason,
                              const char *body, const int status_code);

extend_info_t *hs_client_get_random_intro_from_edge(
                                          const edge_connection_t *edge_conn);

int hs_config_client_authorization(const or_options_t *options,
                                   int validate_only);

int hs_client_reextend_intro_circuit(origin_circuit_t *circ);
void hs_client_close_intro_circuits_from_desc(const hs_descriptor_t *desc);

void hs_client_purge_state(void);

void hs_client_free_all(void);

#ifdef HS_CLIENT_PRIVATE

STATIC int auth_key_filename_is_valid(const char *filename);

STATIC hs_client_service_authorization_t *
parse_auth_file_content(const char *client_key_str);

STATIC routerstatus_t *
pick_hsdir_v3(const ed25519_public_key_t *onion_identity_pk);

STATIC extend_info_t *
client_get_random_intro(const ed25519_public_key_t *service_pk);

STATIC extend_info_t *
desc_intro_point_to_extend_info(const hs_desc_intro_point_t *ip);

STATIC int handle_rendezvous2(origin_circuit_t *circ, const uint8_t *payload,
                              size_t payload_len);

MOCK_DECL(STATIC hs_client_fetch_status_t,
          fetch_v3_desc, (const ed25519_public_key_t *onion_identity_pk));

STATIC void retry_all_socks_conn_waiting_for_desc(void);

STATIC void purge_ephemeral_client_auth(void);

#ifdef TOR_UNIT_TESTS

STATIC void set_hs_client_auths_map(digest256map_t *map);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(HS_CLIENT_PRIVATE) */

#endif /* !defined(TOR_HS_CLIENT_H) */
