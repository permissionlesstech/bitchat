/* Copyright (c) 2023, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file conflux_cell.h
 * \brief Header file for conflux_cell.c.
 **/

#ifndef TOR_CONFLUX_CELL_H
#define TOR_CONFLUX_CELL_H

#include "core/or/or.h"

typedef struct conflux_cell_link_t {
  uint8_t version;
  uint8_t desired_ux;
  uint8_t nonce[DIGEST256_LEN];

  uint64_t last_seqno_sent;
  uint64_t last_seqno_recv;
} conflux_cell_link_t;

conflux_cell_link_t *conflux_cell_new_link(const uint8_t *nonce,
                                           uint64_t last_sent,
                                           uint64_t last_recv,
                                           uint8_t ux);

conflux_cell_link_t *conflux_cell_parse_link(const cell_t *cell,
                                             const uint16_t cell_len);
conflux_cell_link_t *conflux_cell_parse_linked(const cell_t *cell,
                                               const uint16_t cell_le);
uint32_t conflux_cell_parse_switch(const cell_t *cell,
                                   const uint16_t rh_len);

bool conflux_cell_send_link(const conflux_cell_link_t *link,
                            origin_circuit_t *circ);
bool conflux_cell_send_linked(const conflux_cell_link_t *link,
                              or_circuit_t *circ);
bool conflux_cell_send_linked_ack(origin_circuit_t *circ);
bool conflux_send_switch_command(circuit_t *send_circ, uint64_t relative_seq);

#ifdef TOR_UNIT_TESTS

STATIC ssize_t
build_link_cell(const conflux_cell_link_t *link, uint8_t *cell_out);

#endif /* TOR_UNIT_TESTS */

#endif /* TOR_CONFLUX_CELL_H */

