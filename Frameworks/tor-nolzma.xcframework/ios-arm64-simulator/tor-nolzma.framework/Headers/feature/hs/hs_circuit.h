/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_circuit.h
 * \brief Header file containing circuit data for the whole HS subsystem.
 **/

#ifndef TOR_HS_CIRCUIT_H
#define TOR_HS_CIRCUIT_H

#include "core/or/or.h"
#include "lib/crypt_ops/crypto_ed25519.h"

#include "feature/hs/hs_cell.h"
#include "feature/hs/hs_service.h"

/** Pending rendezvous request. This is put in a service priority queue. */
typedef struct pending_rend_t {
  /* Intro point authentication pubkey. */
  ed25519_public_key_t ip_auth_pubkey;
  /* Intro point encryption keypair for the "ntor" type. */
  curve25519_keypair_t ip_enc_key_kp;

  /* Rendezvous data for the circuit. */
  hs_cell_intro_rdv_data_t rdv_data;

  /** Position of element in the heap */
  int idx;

  /** When was this request enqueued. */
  time_t enqueued_ts;
} pending_rend_t;

int top_of_rend_pqueue_is_worthwhile(hs_pow_service_state_t *pow_state);
void rend_pqueue_clear(hs_pow_service_state_t *pow_state);

/* Cleanup function when the circuit is closed or freed. */
void hs_circ_cleanup_on_close(circuit_t *circ);
void hs_circ_cleanup_on_free(circuit_t *circ);
void hs_circ_cleanup_on_repurpose(circuit_t *circ);

/* Circuit API. */
int hs_circ_service_intro_has_opened(hs_service_t *service,
                                     hs_service_intro_point_t *ip,
                                     const hs_service_descriptor_t *desc,
                                     origin_circuit_t *circ);
void hs_circ_service_rp_has_opened(const hs_service_t *service,
                                   origin_circuit_t *circ);
int hs_circ_launch_intro_point(hs_service_t *service,
                               const hs_service_intro_point_t *ip,
                               extend_info_t *ei,
                               bool direct_conn);
int hs_circ_launch_rendezvous_point(const hs_service_t *service,
                                    const curve25519_public_key_t *onion_key,
                                    const uint8_t *rendezvous_cookie);
void hs_circ_retry_service_rendezvous_point(const origin_circuit_t *circ);

origin_circuit_t *hs_circ_service_get_intro_circ(
                                      const hs_service_intro_point_t *ip);
origin_circuit_t *hs_circ_service_get_established_intro_circ(
                                      const hs_service_intro_point_t *ip);

/* Cell API. */
int hs_circ_handle_intro_established(const hs_service_t *service,
                                     const hs_service_intro_point_t *ip,
                                     origin_circuit_t *circ,
                                     const uint8_t *payload,
                                     size_t payload_len);
struct hs_subcredential_t;
int hs_circ_handle_introduce2(const hs_service_t *service,
                              const origin_circuit_t *circ,
                              hs_service_intro_point_t *ip,
                              const struct hs_subcredential_t *subcredential,
                              const uint8_t *payload, size_t payload_len);
int hs_circ_send_introduce1(origin_circuit_t *intro_circ,
                            origin_circuit_t *rend_circ,
                            const hs_desc_intro_point_t *ip,
                            const struct hs_subcredential_t *subcredential,
                            const hs_pow_solution_t *pow_solution);
int hs_circ_send_establish_rendezvous(origin_circuit_t *circ);

/* e2e circuit API. */

int hs_circuit_setup_e2e_rend_circ(origin_circuit_t *circ,
                                   const uint8_t *ntor_key_seed,
                                   size_t seed_len,
                                   int is_service_side);
int hs_circuit_setup_e2e_rend_circ_legacy_client(origin_circuit_t *circ,
                                          const uint8_t *rend_cell_body);

bool hs_circ_is_rend_sent_in_intro1(const origin_circuit_t *circ);

void hs_circ_setup_congestion_control(origin_circuit_t *origin_circ,
                                      uint8_t sendme_inc,
                                      bool is_single_onion);

#ifdef HS_CIRCUIT_PRIVATE

struct hs_ntor_rend_cell_keys_t;

STATIC hs_ident_circuit_t *
create_rp_circuit_identifier(const hs_service_t *service,
                             const uint8_t *rendezvous_cookie,
                             const curve25519_public_key_t *server_pk,
                             const struct hs_ntor_rend_cell_keys_t *keys);

MOCK_DECL(STATIC void,
launch_rendezvous_point_circuit,(const hs_service_t *service,
                                 const ed25519_public_key_t *ip_auth_pubkey,
                                 const curve25519_keypair_t *ip_enc_key_kp,
                                 const hs_cell_intro_rdv_data_t *rdv_data,
                                 time_t now));

#endif /* defined(HS_CIRCUIT_PRIVATE) */

#endif /* !defined(TOR_HS_CIRCUIT_H) */
