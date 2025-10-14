/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file destroy_cell_queue_st.h
 * @brief Destroy-cell queue structures
 **/

#ifndef DESTROY_CELL_QUEUE_ST_H
#define DESTROY_CELL_QUEUE_ST_H

#include "core/or/cell_queue_st.h"

/** A single queued destroy cell. */
struct destroy_cell_t {
  TOR_SIMPLEQ_ENTRY(destroy_cell_t) next;
  circid_t circid;
  uint32_t inserted_timestamp; /**< Time (in timestamp units) when this cell
                                * was inserted */
  uint8_t reason;
};

/** A queue of destroy cells on a channel. */
struct destroy_cell_queue_t {
  /** Linked list of packed_cell_t */
  TOR_SIMPLEQ_HEAD(dcell_simpleq_t, destroy_cell_t) head;
  int n; /**< The number of cells in the queue. */
};

#endif /* !defined(DESTROY_CELL_QUEUE_ST_H) */
