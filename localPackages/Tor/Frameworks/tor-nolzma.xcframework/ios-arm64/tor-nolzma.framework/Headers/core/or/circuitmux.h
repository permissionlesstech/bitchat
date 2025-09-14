/* * Copyright (c) 2012-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitmux.h
 * \brief Header file for circuitmux.c
 **/

#ifndef TOR_CIRCUITMUX_H
#define TOR_CIRCUITMUX_H

#include "core/or/or.h"
#include "lib/testsupport/testsupport.h"

typedef struct circuitmux_policy_t circuitmux_policy_t;
typedef struct circuitmux_policy_data_t circuitmux_policy_data_t;
typedef struct circuitmux_policy_circ_data_t circuitmux_policy_circ_data_t;

struct circuitmux_policy_t {
  /* Allocate cmux-wide policy-specific data */
  circuitmux_policy_data_t * (*alloc_cmux_data)(circuitmux_t *cmux);
  /* Free cmux-wide policy-specific data */
  void (*free_cmux_data)(circuitmux_t *cmux,
                         circuitmux_policy_data_t *pol_data);
  /* Allocate circuit policy-specific data for a newly attached circuit */
  circuitmux_policy_circ_data_t *
    (*alloc_circ_data)(circuitmux_t *cmux,
                       circuitmux_policy_data_t *pol_data,
                       circuit_t *circ,
                       cell_direction_t direction,
                       unsigned int cell_count);
  /* Free circuit policy-specific data */
  void (*free_circ_data)(circuitmux_t *cmux,
                         circuitmux_policy_data_t *pol_data,
                         circuit_t *circ,
                         circuitmux_policy_circ_data_t *pol_circ_data);
  /* Notify that a circuit has become active/inactive */
  void (*notify_circ_active)(circuitmux_t *cmux,
                             circuitmux_policy_data_t *pol_data,
                             circuit_t *circ,
                             circuitmux_policy_circ_data_t *pol_circ_data);
  void (*notify_circ_inactive)(circuitmux_t *cmux,
                               circuitmux_policy_data_t *pol_data,
                               circuit_t *circ,
                               circuitmux_policy_circ_data_t *pol_circ_data);
  /* Notify of arriving/transmitted cells on a circuit */
  void (*notify_set_n_cells)(circuitmux_t *cmux,
                             circuitmux_policy_data_t *pol_data,
                             circuit_t *circ,
                             circuitmux_policy_circ_data_t *pol_circ_data,
                             unsigned int n_cells);
  void (*notify_xmit_cells)(circuitmux_t *cmux,
                            circuitmux_policy_data_t *pol_data,
                            circuit_t *circ,
                            circuitmux_policy_circ_data_t *pol_circ_data,
                            unsigned int n_cells);
  /* Choose a circuit */
  circuit_t * (*pick_active_circuit)(circuitmux_t *cmux,
                                     circuitmux_policy_data_t *pol_data);
  /* Optional: channel comparator for use by the scheduler */
  int (*cmp_cmux)(circuitmux_t *cmux_1, circuitmux_policy_data_t *pol_data_1,
                  circuitmux_t *cmux_2, circuitmux_policy_data_t *pol_data_2);
};

/*
 * Circuitmux policy implementations can subclass this to store circuitmux-
 * wide data; it just has the magic number in the base struct.
 */

struct circuitmux_policy_data_t {
  uint32_t magic;
};

/*
 * Circuitmux policy implementations can subclass this to store circuit-
 * specific data; it just has the magic number in the base struct.
 */

struct circuitmux_policy_circ_data_t {
  uint32_t magic;
};

/*
 * Upcast #defines for the above types
 */

/**
 * Convert a circuitmux_policy_data_t subtype to a circuitmux_policy_data_t.
 */

#define TO_CMUX_POL_DATA(x)  (&((x)->base_))

/**
 * Convert a circuitmux_policy_circ_data_t subtype to a
 * circuitmux_policy_circ_data_t.
 */

#define TO_CMUX_POL_CIRC_DATA(x)  (&((x)->base_))

/* Consistency check */
void circuitmux_assert_okay(circuitmux_t *cmux);

/* Create/destroy */
circuitmux_t * circuitmux_alloc(void);
void circuitmux_detach_all_circuits(circuitmux_t *cmux,
                                    smartlist_t *detached_out);
void circuitmux_free_(circuitmux_t *cmux);
#define circuitmux_free(cmux) \
  FREE_AND_NULL(circuitmux_t, circuitmux_free_, (cmux))

/* Policy control */
void circuitmux_clear_policy(circuitmux_t *cmux);
MOCK_DECL(const circuitmux_policy_t *,
          circuitmux_get_policy, (circuitmux_t *cmux));
void circuitmux_set_policy(circuitmux_t *cmux,
                           const circuitmux_policy_t *pol);

/* Status inquiries */
cell_direction_t circuitmux_attached_circuit_direction(
    circuitmux_t *cmux,
    circuit_t *circ);
int circuitmux_is_circuit_attached(circuitmux_t *cmux, circuit_t *circ);
int circuitmux_is_circuit_active(circuitmux_t *cmux, circuit_t *circ);
unsigned int circuitmux_num_cells_for_circuit(circuitmux_t *cmux,
                                              circuit_t *circ);
MOCK_DECL(unsigned int, circuitmux_num_cells, (circuitmux_t *cmux));
unsigned int circuitmux_num_circuits(circuitmux_t *cmux);
unsigned int circuitmux_num_active_circuits(circuitmux_t *cmux);

/* Debugging interface - slow. */
int64_t circuitmux_count_queued_destroy_cells(const channel_t *chan,
                                              const circuitmux_t *cmux);

/* Channel interface */
circuit_t * circuitmux_get_first_active_circuit(circuitmux_t *cmux,
                                    destroy_cell_queue_t **destroy_queue_out);
void circuitmux_notify_xmit_cells(circuitmux_t *cmux, circuit_t *circ,
                                  unsigned int n_cells);
void circuitmux_notify_xmit_destroy(circuitmux_t *cmux);

/* Circuit interface */
MOCK_DECL(void, circuitmux_attach_circuit, (circuitmux_t *cmux,
                                            circuit_t *circ,
                                            cell_direction_t direction));
MOCK_DECL(void, circuitmux_detach_circuit,
          (circuitmux_t *cmux, circuit_t *circ));
void circuitmux_clear_num_cells(circuitmux_t *cmux, circuit_t *circ);
void circuitmux_set_num_cells(circuitmux_t *cmux, circuit_t *circ,
                              unsigned int n_cells);

void circuitmux_append_destroy_cell(channel_t *chan,
                                    circuitmux_t *cmux, circid_t circ_id,
                                    uint8_t reason);
void circuitmux_mark_destroyed_circids_usable(circuitmux_t *cmux,
                                              channel_t *chan);

/* Optional interchannel comparisons for scheduling */
MOCK_DECL(int, circuitmux_compare_muxes,
          (circuitmux_t *cmux_1, circuitmux_t *cmux_2));

#ifdef CIRCUITMUX_PRIVATE

#include "core/or/destroy_cell_queue_st.h"

/*
 * Map of muxinfos for circuitmux_t to use; struct is defined below (name
 * of struct must match HT_HEAD line).
 */
typedef HT_HEAD(chanid_circid_muxinfo_map, chanid_circid_muxinfo_t)
  chanid_circid_muxinfo_map_t;

/*
 * Structures for circuitmux.c
 */

struct circuitmux_t {
  /* Keep count of attached, active circuits */
  unsigned int n_circuits, n_active_circuits;

  /* Total number of queued cells on all circuits */
  unsigned int n_cells;

  /*
   * Map from (channel ID, circuit ID) pairs to circuit_muxinfo_t
   */
  chanid_circid_muxinfo_map_t *chanid_circid_map;

  /** List of queued destroy cells */
  destroy_cell_queue_t destroy_cell_queue;
  /** Boolean: True iff the last cell to circuitmux_get_first_active_circuit
   * returned the destroy queue. Used to force alternation between
   * destroy/non-destroy cells.
   *
   * XXXX There is no reason to think that alternating is a particularly good
   * approach -- it's just designed to prevent destroys from starving other
   * cells completely.
   */
  unsigned int last_cell_was_destroy : 1;
  /** Destroy counter: increment this when a destroy gets queued, decrement
   * when we unqueue it, so we can test to make sure they don't starve.
   */
  int64_t destroy_ctr;

  /*
   * Circuitmux policy; if this is non-NULL, it can override the built-
   * in round-robin active circuits behavior.  This is how EWMA works in
   * the new circuitmux_t world.
   */
  const circuitmux_policy_t *policy;

  /* Policy-specific data */
  circuitmux_policy_data_t *policy_data;
};

#endif /* defined(CIRCUITMUX_PRIVATE) */

#endif /* !defined(TOR_CIRCUITMUX_H) */

