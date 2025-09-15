/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file onion_queue.h
 * \brief Header file for onion_queue.c.
 **/

#ifndef TOR_ONION_QUEUE_H
#define TOR_ONION_QUEUE_H

struct create_cell_t;

void onion_consensus_has_changed(const networkstatus_t *ns);

int onion_pending_add(or_circuit_t *circ, struct create_cell_t *onionskin);
or_circuit_t *onion_next_task(struct create_cell_t **onionskin_out);
int onion_num_pending(uint16_t handshake_type);
void onion_pending_remove(or_circuit_t *circ);
void clear_pending_onions(void);

#endif /* !defined(TOR_ONION_QUEUE_H) */
