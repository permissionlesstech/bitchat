/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file circuit_st.h
 * @brief Base circuit structure.
 **/

#ifndef CIRCUIT_ST_H
#define CIRCUIT_ST_H

#include "core/or/or.h"

#include "lib/container/handles.h"

#include "core/or/cell_queue_st.h"
#include "ext/ht.h"

struct hs_token_t;
struct circpad_machine_spec_t;
struct circpad_machine_runtime_t;
struct congestion_control_t;

/** Number of padding state machines on a circuit. */
#define CIRCPAD_MAX_MACHINES (2)

/** "magic" value for an origin_circuit_t */
#define ORIGIN_CIRCUIT_MAGIC 0x35315243u
/** "magic" value for an or_circuit_t */
#define OR_CIRCUIT_MAGIC 0x98ABC04Fu
/** "magic" value for a circuit that would have been freed by circuit_free,
 * but which we're keeping around until a cpuworker reply arrives.  See
 * circuit_free() for more documentation. */
#define DEAD_CIRCUIT_MAGIC 0xdeadc14c

/**
 * A circuit is a path over the onion routing
 * network. Applications can connect to one end of the circuit, and can
 * create exit connections at the other end of the circuit. AP and exit
 * connections have only one circuit associated with them (and thus these
 * connection types are closed when the circuit is closed), whereas
 * OR connections multiplex many circuits at once, and stay standing even
 * when there are no circuits running over them.
 *
 * A circuit_t structure can fill one of two roles.  First, a or_circuit_t
 * links two connections together: either an edge connection and an OR
 * connection, or two OR connections.  (When joined to an OR connection, a
 * circuit_t affects only cells sent to a particular circID on that
 * connection.  When joined to an edge connection, a circuit_t affects all
 * data.)

 * Second, an origin_circuit_t holds the cipher keys and state for sending data
 * along a given circuit.  At the OP, it has a sequence of ciphers, each
 * of which is shared with a single OR along the circuit.  Separate
 * ciphers are used for data going "forward" (away from the OP) and
 * "backward" (towards the OP).  At the OR, a circuit has only two stream
 * ciphers: one for data going forward, and one for data going backward.
 */
struct circuit_t {
  uint32_t magic; /**< For memory and type debugging: must equal
                   * ORIGIN_CIRCUIT_MAGIC or OR_CIRCUIT_MAGIC. */

  /** Handle entry for handle-based lookup */
  HANDLE_ENTRY(circuit, circuit_t);

  /** The channel that is next in this circuit. */
  channel_t *n_chan;

  /**
   * The circuit_id used in the next (forward) hop of this circuit;
   * this is unique to n_chan, but this ordered pair is globally
   * unique:
   *
   * (n_chan->global_identifier, n_circ_id)
   */
  circid_t n_circ_id;

  /** Queue of cells waiting to be transmitted on n_chan */
  cell_queue_t n_chan_cells;

  /**
   * The hop to which we want to extend this circuit.  Should be NULL if
   * the circuit has attached to a channel.
   */
  extend_info_t *n_hop;

  /** True iff we are waiting for n_chan_cells to become less full before
   * allowing any more cells on this circuit. (Origin circuit only.) */
  unsigned int circuit_blocked_on_n_chan : 1;
  /** True iff we are waiting for p_chan_cells to become less full before
   * allowing any more cells on this circuit. (OR circuit only.) */
  unsigned int circuit_blocked_on_p_chan : 1;

  /** True iff we have queued a delete backwards on this circuit, but not put
   * it on the output buffer. */
  unsigned int p_delete_pending : 1;
  /** True iff we have queued a delete forwards on this circuit, but not put
   * it on the output buffer. */
  unsigned int n_delete_pending : 1;

  /** True iff this circuit has received a DESTROY cell in either direction */
  unsigned int received_destroy : 1;

  /** True iff we have sent a sufficiently random data cell since last
   * we reset send_randomness_after_n_cells. */
  unsigned int have_sent_sufficiently_random_cell : 1;

  uint8_t state; /**< Current status of this circuit. */
  uint8_t purpose; /**< Why are we creating this circuit? */

  /** How many relay data cells can we package (read from edge streams)
   * on this circuit before we receive a circuit-level sendme cell asking
   * for more? */
  int package_window;
  /** How many relay data cells will we deliver (write to edge streams)
   * on this circuit? When deliver_window gets low, we send some
   * circuit-level sendme cells to indicate that we're willing to accept
   * more. */
  int deliver_window;
  /**
   * How many cells do we have until we need to send one that contains
   * sufficient randomness?  Used to ensure that authenticated SENDME cells
   * will reflect some unpredictable information.
   **/
  uint16_t send_randomness_after_n_cells;

  /** FIFO containing the digest of the cells that are just before a SENDME is
   * sent by the client. It is done at the last cell before our package_window
   * goes down to 0 which is when we expect a SENDME.
   *
   * Our current circuit package window is capped to 1000
   * (CIRCWINDOW_START_MAX) which is also the start value. The increment is
   * set to 100 (CIRCWINDOW_INCREMENT) which means we don't allow more than
   * 1000/100 = 10 outstanding SENDME cells worth of data. Meaning that this
   * list can not contain more than 10 digests of DIGEST_LEN bytes (20).
   *
   * At position i in the list, the digest corresponds to the
   * (CIRCWINDOW_INCREMENT * i)-nth cell received since we expect a SENDME to
   * be received containing that cell digest.
   *
   * For example, position 2 (starting at 0) means that we've received 300
   * cells so the 300th cell digest is kept at index 2.
   *
   * At maximum, this list contains 200 bytes plus the smartlist overhead. */
  smartlist_t *sendme_last_digests;

  /** Temporary field used during circuits_handle_oom. */
  uint32_t age_tmp;

  /** For storage while n_chan is pending (state CIRCUIT_STATE_CHAN_WAIT). */
  struct create_cell_t *n_chan_create_cell;

  /** When did circuit construction actually begin (ie send the
   * CREATE cell or begin cannibalization).
   *
   * Note: This timer will get reset if we decide to cannibalize
   * a circuit. It may also get reset during certain phases of hidden
   * service circuit use.
   *
   * We keep this timestamp with a higher resolution than most so that the
   * circuit-build-time tracking code can get millisecond resolution.
   */
  struct timeval timestamp_began;

  /** This timestamp marks when the init_circuit_base constructor ran. */
  struct timeval timestamp_created;

  /** When the circuit was first used, or 0 if the circuit is clean.
   *
   * XXXX Note that some code will artificially adjust this value backward
   * in time in order to indicate that a circuit shouldn't be used for new
   * streams, but that it can stay alive as long as it has streams on it.
   * That's a kludge we should fix.
   *
   * XXX The CBT code uses this field to record when HS-related
   * circuits entered certain states.  This usage probably won't
   * interfere with this field's primary purpose, but we should
   * document it more thoroughly to make sure of that.
   *
   * XXX The SocksPort option KeepaliveIsolateSOCKSAuth will artificially
   * adjust this value forward each time a suitable stream is attached to an
   * already constructed circuit, potentially keeping the circuit alive
   * indefinitely.
   */
  time_t timestamp_dirty;

  uint16_t marked_for_close; /**< Should we close this circuit at the end of
                              * the main loop? (If true, holds the line number
                              * where this circuit was marked.) */
  const char *marked_for_close_file; /**< For debugging: in which file was this
                                      * circuit marked for close? */
  /** For what reason (See END_CIRC_REASON...) is this circuit being closed?
   * This field is set in circuit_mark_for_close and used later in
   * circuit_about_to_free. */
  int marked_for_close_reason;
  /** As marked_for_close_reason, but reflects the underlying reason for
   * closing this circuit.
   */
  int marked_for_close_orig_reason;

  /** Unique ID for measuring tunneled network status requests. */
  uint64_t dirreq_id;

  /** Index in smartlist of all circuits (global_circuitlist). */
  int global_circuitlist_idx;

  /** Various statistics about cells being added to or removed from this
   * circuit's queues; used only if CELL_STATS events are enabled and
   * cleared after being sent to control port. */
  smartlist_t *testing_cell_stats;

  /** If set, points to an HS token that this circuit might be carrying.
   *  Used by the HS circuitmap.  */
  struct hs_token_t *hs_token;
  /** Hashtable node: used to look up the circuit by its HS token using the HS
      circuitmap. */
  HT_ENTRY(circuit_t) hs_circuitmap_node;

  /** Adaptive Padding state machines: these are immutable. The state machines
   *  that come from the consensus are saved to a global structure, to avoid
   *  per-circuit allocations. This merely points to the global copy in
   *  origin_padding_machines or relay_padding_machines that should never
   *  change or get deallocated.
   *
   *  Each element of this array corresponds to a different padding machine,
   *  and we can have up to CIRCPAD_MAX_MACHINES such machines. */
  const struct circpad_machine_spec_t *padding_machine[CIRCPAD_MAX_MACHINES];

  /** Adaptive Padding machine runtime info for above machines. This is
   *  the per-circuit mutable information, such as the current state and
   *  histogram token counts. Some of it is optional (aka NULL).
   *  If a machine is being shut down, these indexes can be NULL
   *  without the corresponding padding_machine being NULL, while we
   *  wait for the other end to respond to our shutdown request.
   *
   *  Each element of this array corresponds to a different padding machine,
   *  and we can have up to CIRCPAD_MAX_MACHINES such machines. */
  struct circpad_machine_runtime_t *padding_info[CIRCPAD_MAX_MACHINES];

  /** padding_machine_ctr increments each time a new padding machine
   * is negotiated. It is used for shutdown conditions, to ensure
   * that STOP commands actually correspond to the current machine,
   * and not a previous one. */
  uint32_t padding_machine_ctr;

  /** Congestion control fields */
  struct congestion_control_t *ccontrol;

  /** Conflux linked circuit information.
   *
   * If this is non-NULL, the circuit is linked and part of a usable set,
   * and for origin_circuit_t subtypes, the circuit purpose is
   * CIRCUIT_PURPOSE_CONFLUX_LINKED.
   *
   * If this is NULL, the circuit could still be part of a pending conflux
   * object, in which case the conflux_pending_nonce field is set, and for
   * origin_circuit_t subtypes, the purpose is
   * CIRCUIT_PURPOSE_CONFLUX_UNLINKED.
  */
  struct conflux_t *conflux;

  /** If set, this circuit is considered *unlinked* and in the pending pool.
   * The nonce value is used to find the other legs. Origin circuits that
   * have this set are in the CIRCUIT_PURPOSE_CONFLUX_UNLINKED purpose.
   *
   * If this is NULL, and conflux object is set, it means this circuit is
   * linked and thus part of a usable set. */
  uint8_t *conflux_pending_nonce;
};

#endif /* !defined(CIRCUIT_ST_H) */
