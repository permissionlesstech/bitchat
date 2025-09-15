/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file shared_random_client.h
 * \brief Header file for shared_random_client.c.
 **/

#ifndef TOR_SHARED_RANDOM_CLIENT_H
#define TOR_SHARED_RANDOM_CLIENT_H

/* Dirauth module. */
#include "feature/dirauth/shared_random.h"

/* Helper functions. */
void sr_srv_encode(char *dst, size_t dst_len, const sr_srv_t *srv);
int get_voting_interval(void);

/* Control port functions. */
char *sr_get_current_for_control(void);
char *sr_get_previous_for_control(void);

/* SRV functions. */
const sr_srv_t *sr_get_current(const networkstatus_t *ns);
const sr_srv_t *sr_get_previous(const networkstatus_t *ns);
sr_srv_t *sr_parse_srv(const smartlist_t *args);

/*
 * Shared Random State API
 */

/* Each protocol phase has 12 rounds  */
#define SHARED_RANDOM_N_ROUNDS 12
/* Number of phase we have in a protocol. */
#define SHARED_RANDOM_N_PHASES 2

time_t sr_state_get_start_time_of_current_protocol_run(void);
time_t sr_state_get_start_time_of_previous_protocol_run(void);
unsigned int sr_state_get_phase_duration(void);
unsigned int sr_state_get_protocol_run_duration(void);

#ifdef TOR_UNIT_TESTS

#endif /* TOR_UNIT_TESTS */

#endif /* !defined(TOR_SHARED_RANDOM_CLIENT_H) */
