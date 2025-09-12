/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file cpath_build_state_st.h
 * @brief Circuit-build-stse structure
 **/

#ifndef CIRCUIT_BUILD_STATE_ST_ST_H
#define CIRCUIT_BUILD_STATE_ST_ST_H

/** Information used to build a circuit. */
struct cpath_build_state_t {
  /** Intended length of the final circuit. */
  int desired_path_len;
  /** How to extend to the planned exit node. */
  extend_info_t *chosen_exit;
  /** Whether every node in the circ must have adequate uptime. */
  unsigned int need_uptime : 1;
  /** Whether every node in the circ must have adequate capacity. */
  unsigned int need_capacity : 1;
  /** Whether the last hop was picked with exiting in mind. */
  unsigned int is_internal : 1;
  /** Is this an IPv6 ORPort self-testing circuit? */
  unsigned int is_ipv6_selftest : 1;
  /** Did we pick this as a one-hop tunnel (not safe for other streams)?
   * These are for encrypted dir conns that exit to this router, not
   * for arbitrary exits from the circuit. */
  unsigned int onehop_tunnel : 1;
  /** Indicating the exit needs to support Conflux. */
  unsigned int need_conflux: 1;
  /** How many times has building a circuit for this task failed? */
  int failure_count;
  /** At what time should we give up on this task? */
  time_t expiry_time;
};

#endif /* !defined(CIRCUIT_BUILD_STATE_ST_ST_H) */
