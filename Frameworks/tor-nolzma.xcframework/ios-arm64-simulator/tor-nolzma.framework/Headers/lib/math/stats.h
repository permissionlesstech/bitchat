/* Copyright (c) 2022, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file stats.h
 *
 * \brief Header for stats.c
 **/

#ifndef TOR_STATS_H
#define TOR_STATS_H

/**
 * Compute an N-count EWMA, aka N-EWMA. N-EWMA is defined as:
 *  EWMA = alpha*value + (1-alpha)*EWMA_prev
 * with alpha = 2/(N+1).
 *
 * This works out to:
 *  EWMA = value*2/(N+1) + EMA_prev*(N-1)/(N+1)
 *       = (value*2 + EWMA_prev*(N-1))/(N+1)
 */
static inline double
n_count_ewma_double(double avg, double value, uint64_t N)
{
  /* If the average was not previously computed, return value.
   * The less than is because we have stupid C warning flags that
   * prevent exact comparison to 0.0, so we can't do an exact
   * check for uninitialized double values. Yay pedantry!
   * Love it when it introduces surprising edge case bugs like
   * this will. */
  if (avg < 0.0000002)
    return value;
  else
    return (2*value + (N-1)*avg)/(N+1);
}

/* For most stats, an N_EWMA of 100 is sufficient */
#define DEFAULT_STATS_N_EWMA_COUNT 100
#define stats_update_running_avg(avg, value) \
    n_count_ewma_double(avg, value, DEFAULT_STATS_N_EWMA_COUNT)

#endif /* !defined(TOR_STATS_H) */
