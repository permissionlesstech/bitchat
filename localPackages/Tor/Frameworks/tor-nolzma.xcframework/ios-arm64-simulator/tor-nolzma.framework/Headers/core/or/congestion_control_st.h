/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file congestion_control_st.h
 * \brief Structure definitions for congestion control.
 **/

#ifndef CONGESTION_CONTROL_ST_H
#define CONGESTION_CONTROL_ST_H

#include "core/or/crypt_path_st.h"
#include "core/or/circuit_st.h"

/** Signifies which sendme algorithm to use */
typedef enum {
  /** OG Tor fixed-sized circ and stream windows. It sucks, but it is important
   * to make sure that the new algs can compete with the old garbage. */
  CC_ALG_SENDME = 0,

  /**
   * Prop#324 TOR_WESTWOOD - Deliberately aggressive. Westwood may not even
   * converge to fairness in some cases because max RTT will also increase
   * on congestion, which boosts the Westwood RTT congestion threshold. So it
   * can cause runaway queue bloat, which may or may not lead to a robot
   * uprising... Ok that's Westworld, not Westwood. Still, we need to test
   * Vegas and NOLA against something more aggressive to ensure they do not
   * starve in the presence of cheaters. We also need to make sure cheaters
   * trigger the oomkiller in those cases.
   */
  CC_ALG_WESTWOOD = 1,

  /**
   * Prop#324 TOR_VEGAS - TCP Vegas-style BDP tracker. Because Vegas backs off
   * whenever it detects queue delay, it can be beaten out by more aggressive
   * algs. However, in live network testing, it seems to do just fine against
   * current SENDMEs. It outperforms Westwood and does not stall. */
  CC_ALG_VEGAS = 2,

  /**
   * Prop#324: TOR_NOLA - NOLA looks the BDP right in the eye and uses it
   * immediately as CWND. No slow start, no other congestion signals, no delay,
   * no bullshit. Like TOR_VEGAS, it also uses aggressive BDP estimates, to
   * avoid out-competition. It seems a bit better throughput than Vegas, but
   * its aggressive BDP and rapid updates may lead to more queue latency. */
  CC_ALG_NOLA = 3,
} cc_alg_t;

/* Total number of CC algs in cc_alg_t enum */
#define NUM_CC_ALGS  (CC_ALG_NOLA+1)

/** Signifies how we estimate circuit BDP */
typedef enum {
  /* CWND-based BDP will respond to changes in RTT only, and is relative
   * to cwnd growth. So in slow-start, this will under-estimate BDP */
  BDP_ALG_CWND_RTT = 0,

  /* Sendme-based BDP will quickly measure BDP in less than
   * a cwnd worth of data when in use. So it should be good for slow-start.
   * But if the link goes idle, it will be vastly lower than true BDP. Thus,
   * this estimate gets reset when the cwnd is not fully utilized. */
  BDP_ALG_SENDME_RATE = 1,

  /* Inflight BDP is similar to the cwnd estimator, except it uses
   * packets inflight minus local circuit queues instead of current cwnd.
   * Because it is strictly less than or equal to the cwnd, it will cause
   * the cwnd to drift downward. It is only used if the local OR connection
   * is blocked. */
  BDP_ALG_INFLIGHT_RTT = 2,

  /* The Piecewise BDP estimator uses the CWND estimator before there
   * are sufficient SENDMEs to calculate the SENDME estimator. At that
   * point, it uses the SENDME estimator, unless the local OR connection
   * becomes blocked. In that case, it switches to the inflight estimator. */
  BDP_ALG_PIECEWISE = 3,

} bdp_alg_t;

/** Total number of BDP algs in bdp_alg_t enum */
#define NUM_BDP_ALGS (BDP_ALG_PIECEWISE+1)

/** Vegas algorithm parameters. */
struct vegas_params_t {
    /** The slow-start cwnd cap for RFC3742 */
    uint32_t ss_cwnd_cap;
    /** The maximum slow-start cwnd */
    uint32_t ss_cwnd_max;
    /** The queue use allowed before we exit slow start */
    uint16_t gamma;
    /** The queue use below which we increment cwnd */
    uint16_t alpha;
    /** The queue use above which we decrement cwnd */
    uint16_t beta;
    /** The queue use at which we cap cwnd in steady state */
    uint16_t delta;
    /** Weighted average (percent) between cwnd estimator and
     * piecewise estimator. */
    uint8_t bdp_mix_pct;
};

/** Fields common to all congestion control algorithms */
struct congestion_control_t {
  /**
   * Smartlist of uint64_t monotime usec timestamps of when we sent a data
   * cell that is pending a sendme. FIFO queue that is managed similar to
   * sendme_last_digests. */
  smartlist_t *sendme_pending_timestamps;

  /** RTT time data for congestion control. */
  uint64_t ewma_rtt_usec;
  uint64_t min_rtt_usec;
  uint64_t max_rtt_usec;

  /* Vegas BDP estimate */
  uint64_t bdp;

  /** Congestion window */
  uint64_t cwnd;

  /** Number of cells in-flight (sent but awaiting SENDME ack). */
  uint64_t inflight;

  /**
   * For steady-state: the number of sendme acks until we will acknowledge
   * a congestion event again. It starts out as the number of sendme acks
   * in a congestion window and is decremented each ack. When this reaches
   * 0, it means we should examine our congestion algorithm conditions.
   * In this way, we only react to one congestion event per congestion window.
   *
   * It is also reset to 0 immediately whenever the circuit's orconn is
   * blocked, and when a previously blocked orconn is unblocked.
   */
  uint16_t next_cc_event;

  /** Counts down until we process a cwnd worth of SENDME acks.
   * Used to track full cwnd status. */
  uint16_t next_cwnd_event;

  /** Are we in slow start? */
  bool in_slow_start;

  /** Has the cwnd become full since last cwnd update? */
  bool cwnd_full;

  /** Is the local channel blocked on us? That's a congestion signal */
  bool blocked_chan;

  /* The following parameters are cached from consensus values upon
   * circuit setup. */

  /** Percent of cwnd to increment by during slow start */
  uint16_t cwnd_inc_pct_ss;

  /** Number of cells to increment cwnd by during steady state */
  uint16_t cwnd_inc;

  /** Minimum congestion window (must be at least sendme_inc) */
  uint16_t cwnd_min;

  /**
   * Number of times per congestion window to update based on congestion
   * signals */
  uint8_t cwnd_inc_rate;

  /**
   * Number of cells to ack with every sendme. Taken from consensus parameter
   * and negotiation during circuit setup. */
  uint8_t sendme_inc;

  /** Which congestion control algorithm to use. Taken from
   * consensus parameter and negotiation during circuit setup. */
  cc_alg_t cc_alg;

  /** Which algorithm to estimate circuit bandwidth with. Taken from
   * consensus parameter during circuit setup. */
  bdp_alg_t bdp_alg;

  /** Vegas-specific parameters. These should not be accessed anywhere
   * other than the congestion_control_vegas.c file. */
  struct vegas_params_t vegas_params;
};

/**
 * Returns the number of sendme acks we will receive before we update cwnd.
 *
 * Congestion control literature recommends only one update of cwnd per
 * cwnd worth of acks. However, we can also tune this to be more frequent
 * by increasing the 'cc_cwnd_inc_rate' consensus parameter. This tuning
 * only applies after slow start.
 *
 * If this returns 0 due to high cwnd_inc_rate, the calling code will
 * update every sendme ack.
 */
static inline uint64_t CWND_UPDATE_RATE(const struct congestion_control_t *cc)
{
  /* We add cwnd_inc_rate*sendme_inc/2 to round to nearest integer number
   * of acks */

  if (cc->in_slow_start) {
    return 1;
  } else {
    return ((cc->cwnd + cc->cwnd_inc_rate*cc->sendme_inc/2)
           / (cc->cwnd_inc_rate*cc->sendme_inc));
  }
}

/**
 * Gives us the number of SENDMEs in a CWND, rounded.
 */
static inline uint64_t SENDME_PER_CWND(const struct congestion_control_t *cc)
{
  /* We add cwnd_inc_rate*sendme_inc/2 to round to nearest integer number
   * of acks */
  return ((cc->cwnd + cc->sendme_inc/2)/cc->sendme_inc);
}

/**
 * Returns the amount to increment the congestion window each update,
 * during slow start.
 *
 * Congestion control literature recommends either doubling the cwnd
 * every cwnd during slow start, or some similar exponential growth
 * (such as 50% more every cwnd, for Vegas).
 *
 * This is controlled by a consensus parameter 'cwnd_inc_pct_ss', which
 * allows us to specify the percent of the current consensus window
 * to update by.
 */
static inline uint64_t CWND_INC_SS(const struct congestion_control_t *cc)
{
  return (cc->cwnd_inc_pct_ss*cc->cwnd/100);
}

/**
 * Returns the amount to increment (and for Vegas, also decrement) the
 * congestion window by, every update period.
 *
 * This is controlled by the cc_cwnd_inc consensus parameter.
 */
#define CWND_INC(cc)           ((cc)->cwnd_inc)

#endif /* !defined(CONGESTION_CONTROL_ST_H) */
