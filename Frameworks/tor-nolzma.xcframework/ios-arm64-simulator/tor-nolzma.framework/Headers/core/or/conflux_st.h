/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file conflux_st.h
 * \brief Structure definitions for conflux multipath
 **/

#ifndef CONFLUX_ST_H
#define CONFLUX_ST_H

#include "core/or/circuit_st.h"
#include "core/or/cell_st.h"
#include "lib/defs/digest_sizes.h"

/**
* Specifies which conflux alg is in use.
*/
typedef enum {
 CONFLUX_ALG_MINRTT = 0,
 CONFLUX_ALG_LOWRTT = 1,
 CONFLUX_ALG_CWNDRTT = 2,
} conflux_alg_t;

/** XXX: Cached consensus params+scheduling alg */
struct conflux_params_t {
  conflux_alg_t alg;
};

struct conflux_leg_t {
  /**
   * For computing ooo_q insertion sequence numbers: Highest absolute
   * sequence number received on each leg, before delivery.
   *
   * As a receiver, this allows us to compute the absolute sequence number
   * of a cell for delivery or insertion into the ooo_q. When a SWITCH cell
   * is received on a leg, the absolute sequence number of that cell is
   * the relative sequence number in that cell, plus the absolute sequence
   * number of that leg from this array. The leg's sequence number
   * is then updated to this value immediately.
   *
   * In this way, we are able to assign absolute sequence numbers to cells
   * immediately, regardless of how many legs or leg switches have occurred,
   * and regardless of the delivery status of each cell versus if it must be
   * queued.
   */
  uint64_t last_seq_recv;

  /**
   * For relative sequencing: Highest absolute sequence number sent on each
   * circuit. The overall absolute current sent sequence number is the highest
   * of these values.
   *
   * As a sender, this allows us to compute a relative sequence number when
   * switching legs. When switching legs, the sender looks up its current
   * absolute sequence number as the maximum of all legs. The sender then
   * compares that to the current sequence number on the leg it is about to
   * send on, and then computes the relative sequence number as the difference
   * between the overall absolute sequence number and the sequence number
   * from the sending leg.
   *
   * In this way, we can use much smaller relative sequence numbers on the
   * wire, as opposed to larger absolute values, at the expense of this
   * bookkeeping overhead on each end.
   */
  uint64_t last_seq_sent;

  /**
   * Current round-trip of the circuit, in usec.
   *
   * XXX: In theory, we could use the congestion control RTTs directly off the
   * circs, but congestion control code has assumptions about the RTT being 0
   * at the start of the circuit, which will *not* be the case here, because we
   * get an RTT off the link circuit. */
  uint64_t circ_rtts_usec;

  /** Exit side only: When was the LINKED cell sent? Used for RTT measurement
   * that sets circ_rtts_usec when the LINKED_ACK is received. */
  uint64_t linked_sent_usec;

  /** Circuit of this leg. */
  circuit_t *circ;
};

/** Fields for conflux multipath support */
struct conflux_t {
  /** Cached parameters for this circuit */
  struct conflux_params_t params;

  /**
   * List of all linked conflux_leg_t for this set. Once a leg is in that list,
   * it can be used to transmit data. */
  smartlist_t *legs;

  /**
   * Out-of-order priority queue of conflux_cell_t *, heapified
   * on conflux_cell_t.seq number (lowest at top of heap).
   *
   * XXX: We are most likely to insert cells at either the head or the tail.
   * Verify that is fast-path wrt smartlist priority queues, and not a memmove
   * nightmare. If so, we may need a real linked list, or a packed_cell_t list.
   */
  smartlist_t *ooo_q;

  /**
   * Absolute sequence number of cells delivered to streams since start.
   * (ie: this is updated *after* dequeue from the ooo_q priority queue). */
  uint64_t last_seq_delivered;

  /**
   * The estimated remaining number of cells we can send on this circuit
   * before we are allowed to switch legs. */
  uint64_t cells_until_switch;

  /** Current circuit leg. Only use this with conflux_get_circ_for_leg() for
   * bounds checking. */
  struct conflux_leg_t *curr_leg;

  /** Previous circuit leg. Only use this with conflux_get_circ_for_leg() for
   * bounds checking. */
  struct conflux_leg_t *prev_leg;

  /** The nonce that joins these */
  uint8_t nonce[DIGEST256_LEN];

  /** Indicate if this conflux set is in full teardown. We mark it at the first
   * close in case of a total teardown so we avoid recursive calls of circuit
   * mark for close. */
  bool in_full_teardown;

  /** Number of leg launch that we've done for this set. We keep this value
   * because there is a maximum allowed in order to avoid side channel(s). */
  unsigned int num_leg_launch;

  /**
   * PolicyHint: Predicted ports/protocol shorthand..
   *
   * XXX: This might be redundant to the circuit's exitpolicy.
   */
};

#endif /* !defined(CONFLUX_ST_H) */
