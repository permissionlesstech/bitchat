/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file cell_queue_st.h
 * @brief Cell queue structures
 **/

#ifndef PACKED_CELL_ST_H
#define PACKED_CELL_ST_H

#include "tor_queue.h"

/** A cell as packed for writing to the network. */
struct packed_cell_t {
  /** Next cell queued on this circuit. */
  TOR_SIMPLEQ_ENTRY(packed_cell_t) next;
  char body[CELL_MAX_NETWORK_SIZE]; /**< Cell as packed for network. */
  uint32_t inserted_timestamp; /**< Time (in timestamp units) when this cell
                                * was inserted */
};

/** A queue of cells on a circuit, waiting to be added to the
 * or_connection_t's outbuf. */
struct cell_queue_t {
  /** Linked list of packed_cell_t*/
  TOR_SIMPLEQ_HEAD(cell_simpleq_t, packed_cell_t) head;
  int n; /**< The number of cells in the queue. */
};

#endif /* !defined(PACKED_CELL_ST_H) */
