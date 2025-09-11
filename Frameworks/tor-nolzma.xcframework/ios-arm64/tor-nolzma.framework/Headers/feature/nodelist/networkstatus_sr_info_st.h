/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file networkstatus_sr_info_st.h
 * @brief Shared-randomness structure.
 **/

#ifndef NETWORKSTATUS_SR_INFO_ST_H
#define NETWORKSTATUS_SR_INFO_ST_H

struct networkstatus_sr_info_t {
  /* Indicate if the dirauth partitipates in the SR protocol with its vote.
   * This is tied to the SR flag in the vote. */
  unsigned int participate:1;
  /* Both vote and consensus: Current and previous SRV. If list is empty,
   * this means none were found in either the consensus or vote. */
  struct sr_srv_t *previous_srv;
  struct sr_srv_t *current_srv;
  /* Vote only: List of commitments. */
  smartlist_t *commits;
};

#endif /* !defined(NETWORKSTATUS_SR_INFO_ST_H) */
