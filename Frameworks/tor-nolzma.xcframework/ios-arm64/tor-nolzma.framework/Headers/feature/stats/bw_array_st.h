/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file bw_array_st.h
 * @brief Declaration for bw_array_t structure and related constants
 **/

#ifndef TOR_FEATURE_STATS_BW_ARRAY_ST_H
#define TOR_FEATURE_STATS_BW_ARRAY_ST_H

/** For how many seconds do we keep track of individual per-second bandwidth
 * totals? */
#define NUM_SECS_ROLLING_MEASURE 10
/** How large are the intervals for which we track and report bandwidth use? */
#define NUM_SECS_BW_SUM_INTERVAL (24*60*60)
/** How far in the past do we remember and publish bandwidth use? */
#define NUM_SECS_BW_SUM_IS_VALID (5*24*60*60)
/** How many bandwidth usage intervals do we remember? (derived) */
#define NUM_TOTALS (NUM_SECS_BW_SUM_IS_VALID/NUM_SECS_BW_SUM_INTERVAL)

/** Structure to track bandwidth use, and remember the maxima for a given
 * time period.
 */
struct bw_array_t {
  /** Observation array: Total number of bytes transferred in each of the last
   * NUM_SECS_ROLLING_MEASURE seconds. This is used as a circular array. */
  uint64_t obs[NUM_SECS_ROLLING_MEASURE];
  int cur_obs_idx; /**< Current position in obs. */
  time_t cur_obs_time; /**< Time represented in obs[cur_obs_idx] */
  uint64_t total_obs; /**< Total for all members of obs except
                       * obs[cur_obs_idx] */
  uint64_t max_total; /**< Largest value that total_obs has taken on in the
                       * current period. */
  uint64_t total_in_period; /**< Total bytes transferred in the current
                             * period. */

  /** When does the next period begin? */
  time_t next_period;
  /** Where in 'maxima' should the maximum bandwidth usage for the current
   * period be stored? */
  int next_max_idx;
  /** How many values in maxima/totals have been set ever? */
  int num_maxes_set;
  /** Circular array of the maximum
   * bandwidth-per-NUM_SECS_ROLLING_MEASURE usage for the last
   * NUM_TOTALS periods */
  uint64_t maxima[NUM_TOTALS];
  /** Circular array of the total bandwidth usage for the last NUM_TOTALS
   * periods */
  uint64_t totals[NUM_TOTALS];
};

#endif /* !defined(TOR_FEATURE_STATS_BW_ARRAY_ST_H) */
