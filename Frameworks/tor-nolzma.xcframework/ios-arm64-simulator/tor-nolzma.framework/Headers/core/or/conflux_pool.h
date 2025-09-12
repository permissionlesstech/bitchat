/* Copyright (c) 2023, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file conflux_pool.h
 * \brief Header file for conflux_pool.c.
 **/

#ifndef TOR_CONFLUX_POOL_H
#define TOR_CONFLUX_POOL_H

#include "core/or/or.h"

void conflux_pool_init(void);
void conflux_pool_free_all(void);

origin_circuit_t *conflux_get_circ_for_conn(const entry_connection_t *conn,
                                            time_t now);

void conflux_predict_new(time_t now);

bool conflux_launch_leg(const uint8_t *nonce);

void conflux_add_guards_to_exclude_list(const origin_circuit_t *circ,
                                        smartlist_t *excluded);
void conflux_add_middles_to_exclude_list(const origin_circuit_t *circ,
                                    smartlist_t *excluded);

void conflux_circuit_has_closed(circuit_t *circ);
void conflux_circuit_has_opened(origin_circuit_t *orig_circ);
void conflux_circuit_about_to_free(circuit_t *circ);

void conflux_process_link(circuit_t *circ, const cell_t *cell,
                          const uint16_t cell_len);
void conflux_process_linked(circuit_t *circ, crypt_path_t *layer_hint,
                            const cell_t *cell, const uint16_t cell_len);
void conflux_process_linked_ack(circuit_t *circ);

typedef struct conflux_t conflux_t;
void conflux_log_set(int loglevel, const conflux_t *cfx, bool is_client);

#ifdef TOR_UNIT_TESTS
bool launch_new_set(int num_legs);
digest256map_t *get_linked_pool(bool is_client);
digest256map_t *get_unlinked_pool(bool is_client);
extern uint8_t DEFAULT_CLIENT_UX;
extern uint8_t DEFAULT_EXIT_UX;
#endif /* defined(UNIT_TESTS) */

#endif /* TOR_CONFLUX_POOL_H */

