/*
 * Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitpadding.h
 * \brief Header file for circuitpadding.c.
 **/

#ifndef TOR_CIRCUITPADDING_H
#define TOR_CIRCUITPADDING_H

#include "trunnel/circpad_negotiation.h"
#include "lib/evloop/timers.h"

struct circuit_t;
struct origin_circuit_t;
struct cell_t;

/**
 * Signed error return with the specific property that negative
 * values mean error codes of various semantics, 0 means success,
 * and positive values are unused.
 *
 * XXX: Tor uses this concept a lot but just calls it int. Should we move
 * this somewhere centralized? Where?
 */
typedef int signed_error_t;

/**
 * These constants specify the types of events that can cause
 * transitions between state machine states.
 *
 * Note that SENT and RECV are relative to this endpoint. For
 * relays, SENT means packets destined towards the client and
 * RECV means packets destined towards the relay. On the client,
 * SENT means packets destined towards the relay, where as RECV
 * means packets destined towards the client.
 */
typedef enum {
  /* A non-padding cell was received. */
  CIRCPAD_EVENT_NONPADDING_RECV = 0,
  /* A non-padding cell was sent. */
  CIRCPAD_EVENT_NONPADDING_SENT = 1,
  /* A padding cell (RELAY_COMMAND_DROP) was sent. */
  CIRCPAD_EVENT_PADDING_SENT = 2,
  /* A padding cell was received. */
  CIRCPAD_EVENT_PADDING_RECV = 3,
  /* We tried to schedule padding but we ended up picking the infinity bin
   * which means that padding was delayed infinitely */
  CIRCPAD_EVENT_INFINITY = 4,
  /* All histogram bins are empty (we are out of tokens) */
  CIRCPAD_EVENT_BINS_EMPTY = 5,
  /* This state has used up its cell count */
  CIRCPAD_EVENT_LENGTH_COUNT = 6
} circpad_event_t;
#define CIRCPAD_NUM_EVENTS ((int)CIRCPAD_EVENT_LENGTH_COUNT+1)

/** Boolean type that says if we decided to transition states or not */
typedef enum {
  CIRCPAD_STATE_UNCHANGED = 0,
  CIRCPAD_STATE_CHANGED = 1
} circpad_decision_t;

/** The type for the things in histogram bins (aka tokens) */
typedef uint32_t circpad_hist_token_t;

/** The type for histogram indexes (needs to be negative for errors) */
typedef int8_t circpad_hist_index_t;

/** The type for absolute time, from monotime_absolute_usec() */
typedef uint64_t circpad_time_t;

/** The type for timer delays, in microseconds */
typedef uint32_t circpad_delay_t;
#define CIRCPAD_DELAY_UNITS_PER_SECOND  (1000*1000)

/**
 * An infinite padding cell delay means don't schedule any padding --
 * simply wait until a different event triggers a transition.
 *
 * This means that the maximum delay we can schedule is UINT32_MAX-1
 * microseconds, or about 4300 seconds (1.25 hours).
 * XXX: Is this enough if we want to simulate light, intermittent
 * activity on an onion service?
 */
#define CIRCPAD_DELAY_INFINITE  (UINT32_MAX)

/**
 * This is the maximum delay that the circuit padding system can have, in
 * seconds.
 */
#define CIRCPAD_DELAY_MAX_SECS   \
    ((CIRCPAD_DELAY_INFINITE/CIRCPAD_DELAY_UNITS_PER_SECOND)+1)

/**
 * Macro to clarify when we're checking the infinity bin.
 *
 * Works with either circpad_state_t or circpad_machine_runtime_t
 */
#define CIRCPAD_INFINITY_BIN(mi)  ((mi)->histogram_len-1)

/**
 * These constants form a bitfield that specifies when a state machine
 * should be applied to a circuit.
 *
 * If any of these elements is set, then the circuit will be tested against
 * that specific condition. If an element is unset, then we don't test it.
 * (E.g., if neither NO_STREAMS or STREAMS are set, then we will not care
 * whether a circuit has streams attached when we apply a state machine.)
 *
 * The helper function circpad_circuit_state() converts circuit state
 * flags into this more compact representation.
 */
typedef enum {
  /* Only apply machine if the circuit is still building */
  CIRCPAD_CIRC_BUILDING = 1<<0,
  /* Only apply machine if the circuit is open */
  CIRCPAD_CIRC_OPENED = 1<<1,
  /* Only apply machine if the circuit has no attached streams */
  CIRCPAD_CIRC_NO_STREAMS = 1<<2,
  /* Only apply machine if the circuit has attached streams */
  CIRCPAD_CIRC_STREAMS = 1<<3,
  /* Only apply machine if the circuit still allows RELAY_EARLY cells */
  CIRCPAD_CIRC_HAS_RELAY_EARLY = 1<<4,
  /* Only apply machine if the circuit has depleted its RELAY_EARLY cells
   * allowance. */
  CIRCPAD_CIRC_HAS_NO_RELAY_EARLY = 1<<5
} circpad_circuit_state_t;

/** Bitmask that says "apply this machine to all states" */
#define CIRCPAD_STATE_ALL   \
    (CIRCPAD_CIRC_BUILDING|CIRCPAD_CIRC_OPENED| \
     CIRCPAD_CIRC_STREAMS|CIRCPAD_CIRC_NO_STREAMS| \
     CIRCPAD_CIRC_HAS_RELAY_EARLY|CIRCPAD_CIRC_HAS_NO_RELAY_EARLY)

/**
 * A compact circuit purpose bitfield mask that allows us to compactly
 * specify which circuit purposes a machine should apply to.
 *
 * The helper function circpad_circ_purpose_to_mask() converts circuit
 * purposes into bit positions in this bitmask.
 */
typedef uint32_t circpad_purpose_mask_t;

/** Bitmask that says "apply this machine to all purposes". */
#define CIRCPAD_PURPOSE_ALL (0xFFFFFFFF)

/**
 * This type specifies all of the conditions that must be met before
 * a client decides to initiate padding on a circuit.
 *
 * A circuit must satisfy every sub-field in this type in order
 * to be considered to match the conditions.
 */
typedef struct circpad_machine_conditions_t {
  /** Only apply the machine *if* the circuit has at least this many hops */
  unsigned min_hops : 3;

  /** Only apply the machine *if* vanguards are enabled */
  unsigned requires_vanguards : 1;

  /**
   * This machine is ok to use if reduced padding is set in consensus
   * or torrc. This machine will still be applied even if reduced padding
   * is not set; this flag only acts to exclude machines that don't have
   * it set when reduced padding is requested. Therefore, reduced padding
   * machines should appear at the lowest priority in the padding machine
   * lists (aka first in the list), so that non-reduced padding machines
   * for the same purpose are given a chance to apply when reduced padding
   * is not requested. */
  unsigned reduced_padding_ok : 1;

  /** Only apply the machine *if* the circuit's state matches any of
   *  the bits set in this bitmask. */
  circpad_circuit_state_t apply_state_mask;

  /** Only apply a machine *if* the circuit's purpose matches one
   *  of the bits set in this bitmask */
  circpad_purpose_mask_t apply_purpose_mask;

  /** Keep a machine if any of the circuits's state machine's match
   *  the bits set in this bitmask, but don't apply new machines if
   *  they match this mask. */
  circpad_circuit_state_t keep_state_mask;

  /** Keep a machine if any of the circuits's state machine's match
   *  the bits set in this bitmask, but don't apply new machines if
   *  they match this mask. */
  circpad_purpose_mask_t keep_purpose_mask;

} circpad_machine_conditions_t;

/**
 * Token removal strategy options.
 *
 * The WTF-PAD histograms are meant to specify a target distribution to shape
 * traffic towards. This is accomplished by removing tokens from the histogram
 * when either padding or non-padding cells are sent.
 *
 * When we see a non-padding cell at a particular time since the last cell, you
 * remove a token from the corresponding delay bin. These flags specify
 * which bin to choose if that bin is already empty.
 */
typedef enum {
  /** Don't remove any tokens */
  CIRCPAD_TOKEN_REMOVAL_NONE = 0,
  /**
   * Remove from the first non-zero higher bin index when current is zero.
   * This is the recommended strategy from the Adaptive Padding paper. */
  CIRCPAD_TOKEN_REMOVAL_HIGHER = 1,
  /** Remove from the first non-zero lower bin index when current is empty. */
  CIRCPAD_TOKEN_REMOVAL_LOWER = 2,
  /** Remove from the closest non-zero bin index when current is empty. */
  CIRCPAD_TOKEN_REMOVAL_CLOSEST = 3,
  /** Remove from the closest bin by time value (since bins are
   *  exponentially spaced). */
  CIRCPAD_TOKEN_REMOVAL_CLOSEST_USEC = 4,
  /** Only remove from the exact bin corresponding to this delay. If
   *  the bin is 0, simply do nothing. Don't pick another bin. */
  CIRCPAD_TOKEN_REMOVAL_EXACT = 5
} circpad_removal_t;

/**
 * Distribution types supported by circpad_distribution_sample().
 *
 * These can be used instead of histograms for the inter-packet
 * timing distribution, or to specify a distribution on the number
 * of cells that can be sent while in a specific state of the state
 * machine.
 *
 * Each distribution takes up to two parameters which are described below. */
typedef enum {
  /* No probability distribution is used */
  CIRCPAD_DIST_NONE = 0,
  /* Uniform distribution: param1 is lower bound and param2 is upper bound */
  CIRCPAD_DIST_UNIFORM = 1,
  /* Logistic distribution: param1 is Mu, param2 is sigma. */
  CIRCPAD_DIST_LOGISTIC = 2,
  /* Log-logistic distribution: param1 is Alpha, param2 is 1.0/Beta */
  CIRCPAD_DIST_LOG_LOGISTIC = 3,
  /* Geometric distribution: param1 is 'p' (success probability) */
  CIRCPAD_DIST_GEOMETRIC = 4,
  /* Weibull distribution: param1 is k, param2 is Lambda */
  CIRCPAD_DIST_WEIBULL = 5,
  /* Generalized Pareto distribution: param1 is sigma, param2 is xi */
  CIRCPAD_DIST_PARETO = 6
} circpad_distribution_type_t;

/**
 * Distribution information.
 *
 * This type specifies a specific distribution above, as well as
 * up to two parameters for that distribution. The specific
 * per-distribution meaning of these parameters is specified
 * in circpad_distribution_sample().
 */
typedef struct circpad_distribution_t {
  circpad_distribution_type_t type;
  double param1;
  double param2;
} circpad_distribution_t;

/** State number type. Represents current state of state machine. */
typedef uint16_t circpad_statenum_t;
#define  CIRCPAD_STATENUM_MAX   (UINT16_MAX)

/** A histogram can be used to sample padding delays given a machine state.
 * This constant defines the maximum histogram width (i.e. the max number of
 * bins).
 *
 * The current limit is arbitrary and could be raised if there is a need,
 * however too many bins will be hard to serialize in the future.
 *
 * Memory concerns are not so great here since the corresponding histogram and
 * histogram_edges arrays are global and not per-circuit.
 *
 * If we ever upgrade this to a value that can't be represented by 8-bits we
 * also need to upgrade circpad_hist_index_t.
 */
#define CIRCPAD_MAX_HISTOGRAM_LEN (100)

/**
 * A state of a padding state machine. The information here are immutable and
 * represent the initial form of the state; it does not get updated as things
 * happen. The mutable information that gets updated in runtime are carried in
 * a circpad_machine_runtime_t.
 *
 * This struct describes the histograms and/or probability distributions, as
 * well as parameters of a single state in the adaptive padding machine.
 * Instances of this struct exist in global circpad machine definitions that
 * come from torrc or the consensus.
 */
typedef struct circpad_state_t {
  /**
   * If a histogram is used for this state, this specifies the number of bins
   * of this histogram. Histograms must have at least 2 bins.
   *
   * In particular, the following histogram:
   *
   * Tokens
   *         +
   *      10 |    +----+
   *       9 |    |    |           +---------+
   *       8 |    |    |           |         |
   *       7 |    |    |     +-----+         |
   *       6 +----+ Bin+-----+     |         +---------------+
   *       5 |    | #1 |     |     |         |               |
   *         | Bin|    | Bin | Bin |  Bin #4 |    Bin #5     |
   *         | #0 |    | #2  | #3  |         | (infinity bin)|
   *         |    |    |     |     |         |               |
   *         |    |    |     |     |         |               |
   *       0 +----+----+-----+-----+---------+---------------+
   *         0   100  200   350   500      1000             inf  microseconds
   *
   * would be specified the following way:
   *    histogram_len = 6;
   *    histogram[] =        {   6,  10,   6,  7,    9,     6 }
   *    histogram_edges[] =  { 0, 100, 200, 350, 500, 1000 }
   *
   * The final bin is called the "infinity bin" and if it's chosen we don't
   * schedule any padding. The infinity bin is strange because its lower edge
   * is the max value of possible non-infinite delay allowed by this histogram,
   * and its upper edge is CIRCPAD_DELAY_INFINITE. You can tell if the infinity
   * bin is chosen by inspecting its bin index or inspecting its upper edge.
   *
   * If a delay probability distribution is used for this state, this is set
   * to 0. */
  circpad_hist_index_t histogram_len;
  /** The histogram itself: an array of uint16s of tokens, whose
   *  widths are exponentially spaced, in microseconds.
   *
   *  This array must have histogram_len elements that are strictly
   *  monotonically increasing. */
  circpad_hist_token_t histogram[CIRCPAD_MAX_HISTOGRAM_LEN];
  /* The histogram bin edges in usec.
   *
   * Each element of this array specifies the left edge of the corresponding
   * bin. The rightmost edge is always infinity and is not specified in this
   * array.
   *
   * This array must have histogram_len elements. */
  circpad_delay_t histogram_edges[CIRCPAD_MAX_HISTOGRAM_LEN+1];
  /** Total number of tokens in this histogram. This is a constant and is *not*
   *  decremented every time we spend a token. It's used for initializing and
   *  refilling the histogram. */
  uint32_t histogram_total_tokens;

  /**
   * Represents a delay probability distribution (aka IAT distribution). It's a
   * parametrized way of encoding inter-packet delay information in
   * microseconds. It can be used instead of histograms.
   *
   * If it is used, token_removal below must be set to
   * CIRCPAD_TOKEN_REMOVAL_NONE.
   *
   * Start_usec, range_sec, and rtt_estimates are still applied to the
   * results of sampling from this distribution (range_sec is used as a max).
   */
  circpad_distribution_t iat_dist;
  /*  If a delay probability distribution is used, this is used as the max
   *  value we can sample from the distribution. However, RTT measurements and
   *  dist_added_shift gets applied on top of this value to derive the final
   *  padding delay. */
  circpad_delay_t dist_max_sample_usec;
  /*  If a delay probability distribution is used and this is set, we will add
   *  this value on top of the value sampled from the IAT distribution to
   *  derive the final padding delay (We also add the RTT measurement if it's
   *  enabled.). */
  circpad_delay_t dist_added_shift_usec;

  /**
   * The length dist is a parameterized way of encoding how long this
   * state machine runs in terms of sent padding cells or all
   * sent cells. Values are sampled from this distribution, clamped
   * to max_len, and then start_len is added to that value.
   *
   * It may be specified instead of or in addition to
   * the infinity bins and bins empty conditions. */
  circpad_distribution_t length_dist;
  /** A minimum length value, added to the output of length_dist */
  uint16_t start_length;
  /** A cap on the length value that can be sampled from the length_dist */
  uint64_t max_length;

  /** Should we decrement length when we see a nonpadding packet?
   * XXX: Are there any machines that actually want to set this to 0? There may
   * not be. OTOH, it's only a bit.. */
  unsigned length_includes_nonpadding : 1;

  /**
   * This is an array that specifies the next state to transition to upon
   * receipt an event matching the indicated array index.
   *
   * This aborts our scheduled packet and switches to the state
   * corresponding to the index of the array. Tokens are filled upon
   * this transition.
   *
   * States are allowed to transition to themselves, which means re-schedule
   * a new padding timer. They are also allowed to temporarily "transition"
   * to the "IGNORE" and "CANCEL" pseudo-states. See defines below
   * for details on state behavior and meaning.
   */
  circpad_statenum_t next_state[CIRCPAD_NUM_EVENTS];

  /**
   * If true, estimate the RTT from this relay to the exit/website and add that
   * to start_usec for use as the histogram bin 0 start delay.
   *
   * Right now this is only supported for relay-side state machines.
   */
  unsigned use_rtt_estimate : 1;

  /** This specifies the token removal strategy to use upon padding and
   *  non-padding activity. */
  circpad_removal_t token_removal;
} circpad_state_t;

/**
 * The start state for this machine.
 *
 * In the original WTF-PAD, this is only used for transition to/from
 * the burst state. All other fields are not used. But to simplify the
 * code we've made it a first-class state. This has no performance
 * consequences, but may make naive serialization of the state machine
 * large, if we're not careful about how we represent empty fields.
 */
#define  CIRCPAD_STATE_START       0

/**
 * The burst state for this machine.
 *
 * In the original Adaptive Padding algorithm and in WTF-PAD
 * (https://www.freehaven.net/anonbib/cache/ShWa-Timing06.pdf and
 * https://www.cs.kau.se/pulls/hot/thebasketcase-wtfpad/), the burst
 * state serves to detect bursts in traffic. This is done by using longer
 * delays in its histogram, which represent the expected delays between
 * bursts of packets in the target stream. If this delay expires without a
 * real packet being sent, the burst state sends a padding packet and then
 * immediately transitions to the gap state, which is used to generate
 * a synthetic padding packet train. In this implementation, this transition
 * needs to be explicitly specified in the burst state's transition events.
 *
 * Because of this flexibility, other padding mechanisms can transition
 * between these two states arbitrarily, to encode other dynamics of
 * target traffic.
 */
#define  CIRCPAD_STATE_BURST       1

/**
 * The gap state for this machine.
 *
 * In the original Adaptive Padding algorithm and in WTF-PAD, the gap
 * state serves to simulate an artificial packet train composed of padding
 * packets. It does this by specifying much lower inter-packet delays than
 * the burst state, and transitioning back to itself after padding is sent
 * if these timers expire before real traffic is sent. If real traffic is
 * sent, it transitions back to the burst state.
 *
 * Again, in this implementation, these transitions must be specified
 * explicitly, and other transitions are also permitted.
 */
#define  CIRCPAD_STATE_GAP         2

/**
 * End is a pseudo-state that causes the machine to go completely
 * idle, and optionally get torn down (depending on the
 * value of circpad_machine_spec_t.should_negotiate_end)
 *
 * End MUST NOT occupy a slot in the machine state array.
 */
#define  CIRCPAD_STATE_END         CIRCPAD_STATENUM_MAX

/**
 * "Ignore" is a pseudo-state that means "do not react to this
 * event".
 *
 * "Ignore" MUST NOT occupy a slot in the machine state array.
 */
#define  CIRCPAD_STATE_IGNORE         (CIRCPAD_STATENUM_MAX-1)

/**
 * "Cancel" is a pseudo-state that means "cancel pending timers,
 * but remain in your current state".
 *
 * Cancel MUST NOT occupy a slot in the machine state array.
 */
#define  CIRCPAD_STATE_CANCEL         (CIRCPAD_STATENUM_MAX-2)

/**
 * Since we have 3 pseudo-states, the max state array length is
 * up to one less than cancel's statenum.
 */
#define CIRCPAD_MAX_MACHINE_STATES  (CIRCPAD_STATE_CANCEL-1)

/**
 * Mutable padding machine info.
 *
 * This structure contains mutable information about a padding
 * machine. The mutable information must be kept separate because
 * it exists per-circuit, where as the machines themselves are global.
 * This separation is done to conserve space in the circuit structure.
 *
 * This is the per-circuit state that changes regarding the global state
 * machine. Some parts of it are optional (ie NULL).
 *
 * XXX: Play with layout to minimize space on x64 Linux (most common relay).
 */
typedef struct circpad_machine_runtime_t {
  /** The callback pointer for the padding callbacks.
   *
   *  These timers stick around the machineinfo until the machineinfo's circuit
   *  is closed, at which point the timer is cancelled. For this reason it's
   *  safe to assume that the machineinfo exists if this timer gets
   *  triggered. */
  tor_timer_t *padding_timer;

  /** The circuit for this machine */
  struct circuit_t *on_circ;

  /** A mutable copy of the histogram for the current state.
   *  NULL if remove_tokens is false for that state */
  circpad_hist_token_t *histogram;
  /** Length of the above histogram.
   * XXX: This field *could* be removed at the expense of added
   * complexity+overhead for reaching back into the immutable machine
   * state every time we need to inspect the histogram. It's only a byte,
   * though, so it seemed worth it.
   */
  circpad_hist_index_t histogram_len;
  /** Remove token from this index upon sending padding */
  circpad_hist_index_t chosen_bin;

  /** Stop padding/transition if this many cells sent */
  uint64_t state_length;
#define CIRCPAD_STATE_LENGTH_INFINITE UINT64_MAX

  /** A scaled count of padding packets sent, used to limit padding overhead.
   * When this reaches UINT16_MAX, we cut it and nonpadding_sent in half. */
  uint16_t padding_sent;
  /** A scaled count of non-padding packets sent, used to limit padding
   *  overhead. When this reaches UINT16_MAX, we cut it and padding_sent in
   *  half. */
  uint16_t nonpadding_sent;

  /**
   * Timestamp of the most recent cell event (sent, received, padding,
   * non-padding), in seconds from approx_time().
   *
   * Used as an emergency break to stop holding padding circuits open.
   */
  time_t last_cell_time_sec;

  /**
   * EWMA estimate of the RTT of the circuit from this hop
   * to the exit end, in microseconds. */
  circpad_delay_t rtt_estimate_usec;

  /**
   * The last time we got an event relevant to estimating
   * the RTT. Monotonic time in microseconds since system
   * start.
   */
  circpad_time_t last_received_time_usec;

  /**
   * The time at which we scheduled a non-padding packet,
   * or selected an infinite delay.
   *
   * Monotonic time in microseconds since system start.
   * This is 0 if we haven't chosen a padding delay.
   */
  circpad_time_t padding_scheduled_at_usec;

  /** What state is this machine in? */
  circpad_statenum_t current_state;

  /** Machine counter, for shutdown sync.
   *
   *  Set from circuit_t.padding_machine_ctr, which is incremented each
   *  padding machine instantiation.
   */
  uint32_t machine_ctr;

  /**
   * True if we have scheduled a timer for padding.
   *
   * This is 1 if a timer is pending. It is 0 if
   * no timer is scheduled. (It can be 0 even when
   * padding_was_scheduled_at_usec is non-zero).
   */
  unsigned is_padding_timer_scheduled : 1;

  /**
   * If this is true, we have seen full duplex behavior.
   * Stop updating the RTT.
   */
  unsigned stop_rtt_update : 1;

/** Max number of padding machines on each circuit. If changed,
 * also ensure the machine_index bitwith supports the new size. */
#define CIRCPAD_MAX_MACHINES    (2)
  /** Which padding machine index was this for.
   * (make sure changes to the bitwidth can support the
   * CIRCPAD_MAX_MACHINES define). */
  unsigned machine_index : 1;

} circpad_machine_runtime_t;

/** Helper macro to get an actual state machine from a machineinfo */
#define CIRCPAD_GET_MACHINE(machineinfo) \
    ((machineinfo)->on_circ->padding_machine[(machineinfo)->machine_index])

/**
 * This specifies a particular padding machine to use after negotiation.
 *
 * The constants for machine_num_t are in trunnel.
 * We want to be able to define extra numbers in the consensus/torrc, though.
 */
typedef uint8_t circpad_machine_num_t;

/** Global state machine structure from the consensus */
typedef struct circpad_machine_spec_t {
  /* Just a user-friendly machine name for logs */
  const char *name;

  /** Global machine number */
  circpad_machine_num_t machine_num;

  /** Which machine index slot should this machine go into in
   *  the array on the circuit_t */
  unsigned machine_index : 1;

  /** Send a padding negotiate to shut down machine at end state? */
  unsigned should_negotiate_end : 1;

  // These next three fields are origin machine-only...
  /** Origin side or relay side */
  unsigned is_origin_side : 1;

  /** Which hop in the circuit should we send padding to/from?
   *  1-indexed (ie: hop #1 is guard, #2 middle, #3 exit). */
  unsigned target_hopnum : 3;

  /** If this flag is enabled, don't close circuits that use this machine even
   *  if another part of Tor wants to close this circuit.
   *
   *  If this flag is set, the circuitpadding subsystem will close circuits the
   *  moment the machine transitions to the END state, and only if the circuit
   *  has already been asked to be closed by another part of Tor.
   *
   *  Circuits that should have been closed but were kept open by a padding
   *  machine are re-purposed to CIRCUIT_PURPOSE_C_CIRCUIT_PADDING, hence
   *  machines should take that purpose into account if they are filtering
   *  circuits by purpose. */
  unsigned manage_circ_lifetime : 1;

  /** This machine only kills fascists if the following conditions are met. */
  circpad_machine_conditions_t conditions;

  /** How many padding cells can be sent before we apply overhead limits?
   * XXX: Note that we can only allow up to 64k of padding cells on an
   * otherwise quiet circuit. Is this enough? It's 33MB. */
  uint16_t allowed_padding_count;

  /** Padding percent cap: Stop padding if we exceed this percent overhead.
   * 0 means no limit. Overhead is defined as percent of total traffic, so
   * that we can use 0..100 here. This is the same definition as used in
   * Prop#265. */
  uint8_t max_padding_percent;

  /** State array: indexed by circpad_statenum_t */
  circpad_state_t *states;

  /**
   * Number of states this machine has (ie: length of the states array).
   * XXX: This field is not needed other than for safety. */
  circpad_statenum_t num_states;
} circpad_machine_spec_t;

void circpad_new_consensus_params(const networkstatus_t *ns);

int circpad_marked_circuit_for_padding(circuit_t *circ, int reason);

/**
 * The following are event call-in points that are of interest to
 * the state machines. They are called during cell processing. */
void circpad_deliver_unrecognized_cell_events(struct circuit_t *circ,
                                              cell_direction_t dir);
void circpad_deliver_sent_relay_cell_events(struct circuit_t *circ,
                                            uint8_t relay_command);
void circpad_deliver_recognized_relay_cell_events(struct circuit_t *circ,
                                                  uint8_t relay_command,
                                                  crypt_path_t *layer_hint);

/** Cell events are delivered by the above delivery functions */
void circpad_cell_event_nonpadding_sent(struct circuit_t *on_circ);
void circpad_cell_event_nonpadding_received(struct circuit_t *on_circ);
void circpad_cell_event_padding_sent(struct circuit_t *on_circ);
void circpad_cell_event_padding_received(struct circuit_t *on_circ);

/** Internal events are events the machines send to themselves */
circpad_decision_t
circpad_internal_event_infinity(circpad_machine_runtime_t *mi);
circpad_decision_t
circpad_internal_event_bins_empty(circpad_machine_runtime_t *);
circpad_decision_t circpad_internal_event_state_length_up(
                                  circpad_machine_runtime_t *);

/** Machine creation events are events that cause us to set up or
 *  tear down padding state machines. */
void circpad_machine_event_circ_added_hop(struct origin_circuit_t *on_circ);
void circpad_machine_event_circ_built(struct origin_circuit_t *circ);
void circpad_machine_event_circ_purpose_changed(struct origin_circuit_t *circ);
void circpad_machine_event_circ_has_streams(struct origin_circuit_t *circ);
void circpad_machine_event_circ_has_no_streams(struct origin_circuit_t *circ);
void
circpad_machine_event_circ_has_no_relay_early(struct origin_circuit_t *circ);

void circpad_machines_init(void);
void circpad_machines_free(void);
void circpad_register_padding_machine(circpad_machine_spec_t *machine,
                                      smartlist_t *machine_list);

void circpad_machine_states_init(circpad_machine_spec_t *machine,
                                 circpad_statenum_t num_states);

void circpad_circuit_free_all_machineinfos(struct circuit_t *circ);

bool circpad_padding_is_from_expected_hop(struct circuit_t *circ,
                                         crypt_path_t *from_hop);

/** Serializaton functions for writing to/from torrc and consensus */
char *circpad_machine_spec_to_string(const circpad_machine_spec_t *machine);
const circpad_machine_spec_t *circpad_string_to_machine(const char *str);

/* Padding negotiation between client and middle */
signed_error_t circpad_handle_padding_negotiate(struct circuit_t *circ,
                                      struct cell_t *cell);
signed_error_t circpad_handle_padding_negotiated(struct circuit_t *circ,
                                      struct cell_t *cell,
                                      crypt_path_t *layer_hint);
signed_error_t circpad_negotiate_padding(struct origin_circuit_t *circ,
                          circpad_machine_num_t machine,
                          uint8_t target_hopnum,
                          uint8_t command,
                          uint32_t machine_ctr);
bool circpad_padding_negotiated(struct circuit_t *circ,
                           circpad_machine_num_t machine,
                           uint8_t command,
                           uint8_t response,
                           uint32_t machine_ctr);

circpad_purpose_mask_t circpad_circ_purpose_to_mask(uint8_t circ_purpose);

int circpad_check_received_cell(cell_t *cell, circuit_t *circ,
                                crypt_path_t *layer_hint,
                                const relay_header_t *rh);

MOCK_DECL(circpad_decision_t,
circpad_machine_schedule_padding,(circpad_machine_runtime_t *));

MOCK_DECL(circpad_decision_t,
circpad_machine_spec_transition, (circpad_machine_runtime_t *mi,
                             circpad_event_t event));

circpad_decision_t circpad_send_padding_cell_for_callback(
                                 circpad_machine_runtime_t *mi);

void circpad_free_all(void);

#ifdef CIRCUITPADDING_PRIVATE
STATIC void  machine_spec_free_(circpad_machine_spec_t *m);
#define machine_spec_free(chan) \
  FREE_AND_NULL(circpad_machine_spec_t,machine_spec_free_, (m))

STATIC circpad_delay_t
circpad_machine_sample_delay(circpad_machine_runtime_t *mi);

STATIC bool
circpad_machine_reached_padding_limit(circpad_machine_runtime_t *mi);

STATIC circpad_delay_t
circpad_histogram_bin_to_usec(const circpad_machine_runtime_t *mi,
                              circpad_hist_index_t bin);

STATIC const circpad_state_t *
circpad_machine_current_state(const circpad_machine_runtime_t *mi);

STATIC void circpad_machine_remove_token(circpad_machine_runtime_t *mi);

STATIC circpad_hist_index_t circpad_histogram_usec_to_bin(
                                       const circpad_machine_runtime_t *mi,
                                       circpad_delay_t us);

STATIC circpad_machine_runtime_t *circpad_circuit_machineinfo_new(
                                               struct circuit_t *on_circ,
                                               int machine_index);
STATIC void circpad_machine_remove_higher_token(circpad_machine_runtime_t *mi,
                                         circpad_delay_t target_bin_us);
STATIC void circpad_machine_remove_lower_token(circpad_machine_runtime_t *mi,
                                         circpad_delay_t target_bin_us);
STATIC void circpad_machine_remove_closest_token(circpad_machine_runtime_t *mi,
                                         circpad_delay_t target_bin_us,
                                         bool use_usec);
STATIC void circpad_machine_setup_tokens(circpad_machine_runtime_t *mi);

MOCK_DECL(STATIC signed_error_t,
circpad_send_command_to_hop,(struct origin_circuit_t *circ, uint8_t hopnum,
                             uint8_t relay_command, const uint8_t *payload,
                             ssize_t payload_len));

MOCK_DECL(STATIC const node_t *,
circuit_get_nth_node,(origin_circuit_t *circ, int hop));

STATIC circpad_delay_t
histogram_get_bin_upper_bound(const circpad_machine_runtime_t *mi,
                              circpad_hist_index_t bin);

STATIC void
circpad_add_matching_machines(origin_circuit_t *on_circ,
                              smartlist_t *machines_sl);

#ifdef TOR_UNIT_TESTS
extern smartlist_t *origin_padding_machines;
extern smartlist_t *relay_padding_machines;

#endif

#endif /* defined(CIRCUITPADDING_PRIVATE) */

#endif /* !defined(TOR_CIRCUITPADDING_H) */
