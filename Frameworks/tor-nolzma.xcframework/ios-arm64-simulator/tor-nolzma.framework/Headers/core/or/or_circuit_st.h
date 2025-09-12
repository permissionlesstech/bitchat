/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef OR_CIRCUIT_ST_H
#define OR_CIRCUIT_ST_H

#include "core/or/or.h"

#include "core/or/circuit_st.h"
#include "core/or/crypt_path_st.h"

#include "lib/evloop/token_bucket.h"

struct onion_queue_t;

/** An or_circuit_t holds information needed to implement a circuit at an
 * OR. */
struct or_circuit_t {
  circuit_t base_;

  /** Pointer to an entry on the onion queue, if this circuit is waiting for a
   * chance to give an onionskin to a cpuworker. Used only in onion.c */
  struct onion_queue_t *onionqueue_entry;
  /** Pointer to a workqueue entry, if this circuit has given an onionskin to
   * a cpuworker and is waiting for a response. Used to decide whether it is
   * safe to free a circuit or if it is still in use by a cpuworker. */
  struct workqueue_entry_t *workqueue_entry;

  /** The circuit_id used in the previous (backward) hop of this circuit. */
  circid_t p_circ_id;
  /** Queue of cells waiting to be transmitted on p_conn. */
  cell_queue_t p_chan_cells;
  /** The channel that is previous in this circuit. */
  channel_t *p_chan;
  /** Linked list of Exit streams associated with this circuit.
   *
   * Note that any updates to this pointer must be followed with
   * conflux_update_n_streams() to keep the other legs n_streams
   * in sync. */
  edge_connection_t *n_streams;
  /** Linked list of Exit streams associated with this circuit that are
   * still being resolved.
   *
   * Just like with n_streams, any updates to this pointer must
   * be followed with conflux_update_resolving_streams().
   */
  edge_connection_t *resolving_streams;

  /** Cryptographic state used for encrypting and authenticating relay
   * cells to and from this hop. */
  relay_crypto_t crypto;

  /** Points to spliced circuit if purpose is REND_ESTABLISHED, and circuit
   * is not marked for close. */
  struct or_circuit_t *rend_splice;

  /** Stores KH for the handshake. */
  char rend_circ_nonce[DIGEST_LEN];/* KH in tor-spec.txt */

  /** Number of cells which we have discarded because of having no next hop,
   * despite not recognizing the cell. */
  uint32_t n_cells_discarded_at_end;

  /** How many more relay_early cells can we send on this circuit, according
   * to the specification? */
  unsigned int remaining_relay_early_cells : 4;

  /* We have already received an INTRODUCE1 cell on this circuit. */
  unsigned int already_received_introduce1 : 1;

  /** If set, this circuit carries HS traffic. Consider it in any HS
   *  statistics. */
  unsigned int circuit_carries_hs_traffic_stats : 1;

  /** True iff this circuit was made with a CREATE_FAST cell, or a CREATE[2]
   * cell with a TAP handshake. If this is the case and this is a rend circuit,
   * this is a v2 circuit, otherwise if this is a rend circuit it's a v3
   * circuit. */
  bool used_legacy_circuit_handshake;

  /** Number of cells that were removed from circuit queue; reset every
   * time when writing buffer stats to disk. */
  uint32_t processed_cells;

  /** Total time in milliseconds that cells spent in both app-ward and
   * exit-ward queues of this circuit; reset every time when writing
   * buffer stats to disk. */
  uint64_t total_cell_waiting_time;

  /** If set, the DoS defenses are enabled on this circuit meaning that the
   * introduce2_bucket is initialized and used. */
  unsigned int introduce2_dos_defense_enabled : 1;
  /** If set, the DoS defenses were explicitly enabled through the
   * ESTABLISH_INTRO cell extension. If unset, the consensus is used to learn
   * if the defenses can be enabled or not. */
  unsigned int introduce2_dos_defense_explicit : 1;

  /** INTRODUCE2 cell bucket controlling how much can go on this circuit. Only
   * used if this is a service introduction circuit at the intro point
   * (purpose = CIRCUIT_PURPOSE_INTRO_POINT). */
  token_bucket_ctr_t introduce2_bucket;
};

#endif /* !defined(OR_CIRCUIT_ST_H) */
