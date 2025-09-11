/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitstats.h
 * \brief Header file for circuitstats.c
 **/

#ifndef TOR_CIRCUITSTATS_H
#define TOR_CIRCUITSTATS_H

const circuit_build_times_t *get_circuit_build_times(void);
circuit_build_times_t *get_circuit_build_times_mutable(void);
double get_circuit_build_close_time_ms(void);
double get_circuit_build_timeout_ms(void);

int circuit_build_times_disabled(const or_options_t *options);
int circuit_build_times_disabled_(const or_options_t *options,
                                  int ignore_consensus);

/** A build_time_t is milliseconds */
typedef uint32_t build_time_t;

int circuit_build_times_enough_to_compute(const circuit_build_times_t *cbt);
void circuit_build_times_update_state(const circuit_build_times_t *cbt,
                                      or_state_t *state);
int circuit_build_times_parse_state(circuit_build_times_t *cbt,
                                    or_state_t *state);
void circuit_build_times_count_timeout(circuit_build_times_t *cbt,
                                       int did_onehop);
int circuit_build_times_count_close(circuit_build_times_t *cbt,
                                    int did_onehop, time_t start_time);
void circuit_build_times_set_timeout(circuit_build_times_t *cbt);
int circuit_build_times_add_time(circuit_build_times_t *cbt,
                                 build_time_t time);
int circuit_build_times_needs_circuits(const circuit_build_times_t *cbt);
void circuit_build_times_handle_completed_hop(origin_circuit_t *circ);

int circuit_build_times_needs_circuits_now(const circuit_build_times_t *cbt);
void circuit_build_times_init(circuit_build_times_t *cbt);
void circuit_build_times_free_timeouts(circuit_build_times_t *cbt);
void circuit_build_times_new_consensus_params(circuit_build_times_t *cbt,
                                              const networkstatus_t *ns);
double circuit_build_times_timeout_rate(const circuit_build_times_t *cbt);
double circuit_build_times_close_rate(const circuit_build_times_t *cbt);

void circuit_build_times_update_last_circ(circuit_build_times_t *cbt);
void circuit_build_times_mark_circ_as_measurement_only(origin_circuit_t *circ);
void circuit_build_times_reset(circuit_build_times_t *cbt);

/** Total size of the circuit timeout history to accumulate.
 * 1000 is approx 2.5 days worth of continual-use circuits. */
#define CBT_NCIRCUITS_TO_OBSERVE 1000

/** Width of the histogram bins in milliseconds */
#define CBT_BIN_WIDTH ((build_time_t)10)

/** Number of modes to use in the weighted-avg computation of Xm */
#define CBT_DEFAULT_NUM_XM_MODES 10
#define CBT_MIN_NUM_XM_MODES 1
#define CBT_MAX_NUM_XM_MODES 20

/**
 * CBT_BUILD_ABANDONED is our flag value to represent a force-closed
 * circuit (Aka a 'right-censored' pareto value).
 */
#define CBT_BUILD_ABANDONED ((build_time_t)(INT32_MAX-1))
#define CBT_BUILD_TIME_MAX ((build_time_t)(INT32_MAX))

/** Save state every 10 circuits */
#define CBT_SAVE_STATE_EVERY 10

/* Circuit build times consensus parameters */

/**
 * How long to wait before actually closing circuits that take too long to
 * build in terms of CDF quantile.
 */
#define CBT_DEFAULT_CLOSE_QUANTILE 99
#define CBT_MIN_CLOSE_QUANTILE CBT_MIN_QUANTILE_CUTOFF
#define CBT_MAX_CLOSE_QUANTILE CBT_MAX_QUANTILE_CUTOFF

/**
 * How many circuits count as recent when considering if the
 * connection has gone gimpy or changed.
 */
#define CBT_DEFAULT_RECENT_CIRCUITS 20
#define CBT_MIN_RECENT_CIRCUITS 3
#define CBT_MAX_RECENT_CIRCUITS 1000

/**
 * Maximum count of timeouts that finish the first hop in the past
 * RECENT_CIRCUITS before calculating a new timeout.
 *
 * This tells us whether to abandon timeout history and set
 * the timeout back to whatever circuit_build_times_get_initial_timeout()
 * gives us.
 */
#define CBT_DEFAULT_MAX_RECENT_TIMEOUT_COUNT (CBT_DEFAULT_RECENT_CIRCUITS*9/10)
#define CBT_MIN_MAX_RECENT_TIMEOUT_COUNT 3
#define CBT_MAX_MAX_RECENT_TIMEOUT_COUNT 10000

/** Minimum circuits before estimating a timeout */
#define CBT_DEFAULT_MIN_CIRCUITS_TO_OBSERVE 100
#define CBT_MIN_MIN_CIRCUITS_TO_OBSERVE 1
#define CBT_MAX_MIN_CIRCUITS_TO_OBSERVE 10000

/** Cutoff percentile on the CDF for our timeout estimation. */
#define CBT_DEFAULT_QUANTILE_CUTOFF 80
#define CBT_MIN_QUANTILE_CUTOFF 10
#define CBT_MAX_QUANTILE_CUTOFF 99
double circuit_build_times_quantile_cutoff(void);

/** How often in seconds should we build a test circuit */
#define CBT_DEFAULT_TEST_FREQUENCY 10
#define CBT_MIN_TEST_FREQUENCY 1
#define CBT_MAX_TEST_FREQUENCY INT32_MAX

/** Lowest allowable value for CircuitBuildTimeout in milliseconds */
#define CBT_DEFAULT_TIMEOUT_MIN_VALUE (CBT_BIN_WIDTH)
#define CBT_MIN_TIMEOUT_MIN_VALUE CBT_BIN_WIDTH
#define CBT_MAX_TIMEOUT_MIN_VALUE INT32_MAX

/** Initial circuit build timeout in milliseconds */
#define CBT_DEFAULT_TIMEOUT_INITIAL_VALUE (60*1000)
#define CBT_MIN_TIMEOUT_INITIAL_VALUE CBT_MIN_TIMEOUT_MIN_VALUE
#define CBT_MAX_TIMEOUT_INITIAL_VALUE INT32_MAX
int32_t circuit_build_times_initial_timeout(void);

#if CBT_DEFAULT_MAX_RECENT_TIMEOUT_COUNT < CBT_MIN_MAX_RECENT_TIMEOUT_COUNT
#error "RECENT_CIRCUITS is set too low."
#endif

#ifdef CIRCUITSTATS_PRIVATE
STATIC double circuit_build_times_calculate_timeout(circuit_build_times_t *cbt,
                                             double quantile);
STATIC int circuit_build_times_update_alpha(circuit_build_times_t *cbt);

/* Network liveness functions */
STATIC int circuit_build_times_network_check_changed(
                                             circuit_build_times_t *cbt);
STATIC build_time_t circuit_build_times_get_xm(circuit_build_times_t *cbt);
#endif /* defined(CIRCUITSTATS_PRIVATE) */

#ifdef TOR_UNIT_TESTS
build_time_t circuit_build_times_generate_sample(circuit_build_times_t *cbt,
                                                 double q_lo, double q_hi);
double circuit_build_times_cdf(circuit_build_times_t *cbt, double x);
void circuit_build_times_initial_alpha(circuit_build_times_t *cbt,
                                       double quantile, double time_ms);
void circuitbuild_running_unit_tests(void);
#endif /* defined(TOR_UNIT_TESTS) */

/* Network liveness functions */
void circuit_build_times_network_is_live(circuit_build_times_t *cbt);
int circuit_build_times_network_check_live(const circuit_build_times_t *cbt);
void circuit_build_times_network_circ_success(circuit_build_times_t *cbt);

/** Information about the state of our local network connection */
typedef struct {
  /** The timestamp we last completed a TLS handshake or received a cell */
  time_t network_last_live;
  /** If the network is not live, how many timeouts has this caused? */
  int nonlive_timeouts;
  /** Circular array of circuits that have made it to the first hop. Slot is
   * 1 if circuit timed out, 0 if circuit succeeded */
  int8_t *timeouts_after_firsthop;
  /** Number of elements allocated for the above array */
  int num_recent_circs;
  /** Index into circular array. */
  int after_firsthop_idx;
} network_liveness_t;

/** Structure for circuit build times history */
struct circuit_build_times_t {
  /** The circular array of recorded build times in milliseconds */
  build_time_t circuit_build_times[CBT_NCIRCUITS_TO_OBSERVE];
  /** Current index in the circuit_build_times circular array */
  int build_times_idx;
  /** Total number of build times accumulated. Max CBT_NCIRCUITS_TO_OBSERVE */
  int total_build_times;
  /** Information about the state of our local network connection */
  network_liveness_t liveness;
  /** Last time we built a circuit. Used to decide to build new test circs */
  time_t last_circ_at;
  /** "Minimum" value of our pareto distribution (actually mode) */
  build_time_t Xm;
  /** alpha exponent for pareto dist. */
  double alpha;
  /** Have we computed a timeout? */
  int have_computed_timeout;
  /** The exact value for that timeout in milliseconds. Stored as a double
   * to maintain precision from calculations to and from quantile value. */
  double timeout_ms;
  /** How long we wait before actually closing the circuit. */
  double close_ms;
  /** Total succeeded counts. Old measurements may be scaled downward if
   * we've seen a lot of circuits. */
  uint32_t num_circ_succeeded;
  /** Total timeout counts.  Old measurements may be scaled downward if
   * we've seen a lot of circuits. */
  uint32_t num_circ_timeouts;
  /** Total closed counts.  Old measurements may be scaled downward if
   * we've seen a lot of circuits.*/
  uint32_t num_circ_closed;

};

#endif /* !defined(TOR_CIRCUITSTATS_H) */
