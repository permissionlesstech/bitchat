/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file conflux.h
 * \brief Public APIs for conflux multipath support
 **/

#ifndef TOR_CONFLUX_H
#define TOR_CONFLUX_H

#include "core/or/circuit_st.h"
#include "core/or/conflux_st.h"

typedef struct conflux_t conflux_t;
typedef struct conflux_leg_t conflux_leg_t;

/** Helpers to iterate over legs with better semantic. */
#define CONFLUX_FOR_EACH_LEG_BEGIN(cfx, var) \
  SMARTLIST_FOREACH_BEGIN(cfx->legs, conflux_leg_t *, var)
#define CONFLUX_FOR_EACH_LEG_END(var) \
  SMARTLIST_FOREACH_END(var)

/** Helper: Return the number of legs a conflux object has. */
#define CONFLUX_NUM_LEGS(cfx) (smartlist_len(cfx->legs))

/** A cell for the out-of-order queue.
 * XXX: Consider trying to use packed_cell_t instead here? */
typedef struct {
  /**
   * Absolute sequence number of this cell, computed from the
   * relative sequence number of the conflux cell. */
  uint64_t seq;

  /**
   * Heap index of this cell, for use in in the conflux_t ooo_q heap.
   */
  int heap_idx;

  /** The cell here is always guaranteed to have removed its
   * extra conflux sequence number, for ease of processing */
  cell_t cell;
} conflux_cell_t;

size_t conflux_handle_oom(size_t bytes_to_remove);
uint64_t conflux_get_total_bytes_allocation(void);
uint64_t conflux_get_circ_bytes_allocation(const circuit_t *circ);

void conflux_update_rtt(conflux_t *cfx, circuit_t *circ, uint64_t rtt_usec);

circuit_t *conflux_decide_circ_for_send(conflux_t *cfx,
                                        circuit_t *orig_circ,
                                        uint8_t relay_command);
circuit_t *conflux_decide_next_circ(conflux_t *cfx);

int conflux_process_switch_command(circuit_t *in_circ,
                               crypt_path_t *layer_hint, cell_t *cell,
                               relay_header_t *rh);
bool conflux_should_multiplex(int relay_command);
bool conflux_process_cell(conflux_t *cfx, circuit_t *in_circ,
                          crypt_path_t *layer_hint,
                          cell_t *cell);
conflux_cell_t *conflux_dequeue_cell(conflux_t *cfx);
void conflux_note_cell_sent(conflux_t *cfx, circuit_t *circ,
                            uint8_t relay_command);

/* Private section starts. */
#ifdef TOR_CONFLUX_PRIVATE

const struct congestion_control_t *circuit_ccontrol(const circuit_t *);
conflux_leg_t *conflux_get_leg(conflux_t *cfx, const circuit_t *circ);
uint64_t conflux_get_max_seq_recv(const conflux_t *cfx);
uint64_t conflux_get_max_seq_sent(const conflux_t *cfx);

/*
 * Unit tests declaractions.
 */
#ifdef TOR_UNIT_TESTS

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(TOR_CONFLUX_PRIVATE) */

#endif /* !defined(TOR_CONFLUX_H) */
