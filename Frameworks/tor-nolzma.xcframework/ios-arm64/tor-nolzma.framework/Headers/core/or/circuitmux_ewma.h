/* * Copyright (c) 2012-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitmux_ewma.h
 * \brief Header file for circuitmux_ewma.c
 **/

#ifndef TOR_CIRCUITMUX_EWMA_H
#define TOR_CIRCUITMUX_EWMA_H

#include "core/or/or.h"
#include "core/or/circuitmux.h"

/* The public EWMA policy callbacks object. */
extern circuitmux_policy_t ewma_policy;

/* Externally visible EWMA functions */
void cmux_ewma_set_options(const or_options_t *options,
                           const networkstatus_t *consensus);

void circuitmux_ewma_free_all(void);

#ifdef CIRCUITMUX_EWMA_PRIVATE

/*** EWMA structures ***/

typedef struct cell_ewma_t cell_ewma_t;
typedef struct ewma_policy_data_t ewma_policy_data_t;
typedef struct ewma_policy_circ_data_t ewma_policy_circ_data_t;

/**
 * The cell_ewma_t structure keeps track of how many cells a circuit has
 * transferred recently.  It keeps an EWMA (exponentially weighted moving
 * average) of the number of cells flushed from the circuit queue onto a
 * connection in channel_flush_from_first_active_circuit().
 */

struct cell_ewma_t {
  /** The last 'tick' at which we recalibrated cell_count.
   *
   * A cell sent at exactly the start of this tick has weight 1.0. Cells sent
   * since the start of this tick have weight greater than 1.0; ones sent
   * earlier have less weight. */
  unsigned int last_adjusted_tick;
  /** The EWMA of the cell count. */
  double cell_count;
  /** True iff this is the cell count for a circuit's previous
   * channel. */
  unsigned int is_for_p_chan : 1;
  /** The position of the circuit within the OR connection's priority
   * queue. */
  int heap_index;
};

struct ewma_policy_data_t {
  circuitmux_policy_data_t base_;

  /**
   * Priority queue of cell_ewma_t for circuits with queued cells waiting
   * for room to free up on the channel that owns this circuitmux.  Kept
   * in heap order according to EWMA.  This was formerly in channel_t, and
   * in or_connection_t before that.
   */
  smartlist_t *active_circuit_pqueue;

  /**
   * The tick on which the cell_ewma_ts in active_circuit_pqueue last had
   * their ewma values rescaled.  This was formerly in channel_t, and in
   * or_connection_t before that.
   */
  unsigned int active_circuit_pqueue_last_recalibrated;
};

struct ewma_policy_circ_data_t {
  circuitmux_policy_circ_data_t base_;

  /**
   * The EWMA count for the number of cells flushed from this circuit
   * onto this circuitmux.  Used to determine which circuit to flush
   * from next.  This was formerly in circuit_t and or_circuit_t.
   */
  cell_ewma_t cell_ewma;

  /**
   * Pointer back to the circuit_t this is for; since we're separating
   * out circuit selection policy like this, we can't attach cell_ewma_t
   * to the circuit_t any more, so we can't use SUBTYPE_P directly to a
   * circuit_t like before; instead get it here.
   */
  circuit_t *circ;
};

#define EWMA_POL_DATA_MAGIC 0x2fd8b16aU
#define EWMA_POL_CIRC_DATA_MAGIC 0x761e7747U

/*** Downcasts for the above types ***/

/**
 * Downcast a circuitmux_policy_data_t to an ewma_policy_data_t and assert
 * if the cast is impossible.
 */

static inline ewma_policy_data_t *
TO_EWMA_POL_DATA(circuitmux_policy_data_t *pol)
{
  if (!pol) return NULL;
  else {
    tor_assertf(pol->magic == EWMA_POL_DATA_MAGIC,
                "Mismatch: %"PRIu32" != %"PRIu32,
                pol->magic, EWMA_POL_DATA_MAGIC);
    return DOWNCAST(ewma_policy_data_t, pol);
  }
}

/**
 * Downcast a circuitmux_policy_circ_data_t to an ewma_policy_circ_data_t
 * and assert if the cast is impossible.
 */

static inline ewma_policy_circ_data_t *
TO_EWMA_POL_CIRC_DATA(circuitmux_policy_circ_data_t *pol)
{
  if (!pol) return NULL;
  else {
    tor_assertf(pol->magic == EWMA_POL_CIRC_DATA_MAGIC,
                "Mismatch: %"PRIu32" != %"PRIu32,
                pol->magic, EWMA_POL_CIRC_DATA_MAGIC);
    return DOWNCAST(ewma_policy_circ_data_t, pol);
  }
}

STATIC unsigned cell_ewma_get_current_tick_and_fraction(double *remainder_out);
STATIC void cell_ewma_initialize_ticks(void);

#endif /* defined(CIRCUITMUX_EWMA_PRIVATE) */

#endif /* !defined(TOR_CIRCUITMUX_EWMA_H) */
