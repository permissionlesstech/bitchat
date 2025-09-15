/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file vote_timing_st.h
 * @brief Directory voting schedule structure.
 **/

#ifndef VOTE_TIMING_ST_H
#define VOTE_TIMING_ST_H

/** Describes the schedule by which votes should be generated. */
struct vote_timing_t {
  /** Length in seconds between one consensus becoming valid and the next
   * becoming valid. */
  int vote_interval;
  /** For how many intervals is a consensus valid? */
  int n_intervals_valid;
  /** Time in seconds allowed to propagate votes */
  int vote_delay;
  /** Time in seconds allowed to propagate signatures */
  int dist_delay;
};

#endif /* !defined(VOTE_TIMING_ST_H) */
