/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hibernate.h
 * \brief Header file for hibernate.c.
 **/

#ifndef TOR_HIBERNATE_H
#define TOR_HIBERNATE_H

#include "lib/testsupport/testsupport.h"

int accounting_parse_options(const or_options_t *options, int validate_only);
MOCK_DECL(int, accounting_is_enabled, (const or_options_t *options));
int accounting_get_interval_length(void);
MOCK_DECL(time_t, accounting_get_end_time, (void));
void configure_accounting(time_t now);
uint64_t get_accounting_bytes(void);
void accounting_run_housekeeping(time_t now);
void accounting_add_bytes(size_t n_read, size_t n_written, int seconds);
int accounting_record_bandwidth_usage(time_t now, or_state_t *state);
void hibernate_begin_shutdown(void);
MOCK_DECL(int, we_are_hibernating, (void));
MOCK_DECL(int, we_are_fully_hibernating,(void));
void consider_hibernation(time_t now);
int getinfo_helper_accounting(control_connection_t *conn,
                              const char *question, char **answer,
                              const char **errmsg);
uint64_t get_accounting_max_total(void);
void accounting_free_all(void);
bool accounting_tor_is_dormant(void);

#ifdef HIBERNATE_PRIVATE
/** Possible values of hibernate_state */
typedef enum {
  /** We are running normally. */
  HIBERNATE_STATE_LIVE=1,
  /** We're trying to shut down cleanly, and we'll kill all active connections
   * at shutdown_time. */
  HIBERNATE_STATE_EXITING=2,
  /** We're running low on allocated bandwidth for this period, so we won't
   * accept any new connections. */
  HIBERNATE_STATE_LOWBANDWIDTH=3,
  /** We are hibernating, and we won't wake up till there's more bandwidth to
   * use. */
  HIBERNATE_STATE_DORMANT=4,
  /** We start out in state default, which means we haven't decided which state
   * we're in. */
  HIBERNATE_STATE_INITIAL=5
} hibernate_state_t;

#ifdef TOR_UNIT_TESTS
void hibernate_set_state_for_testing_(hibernate_state_t newstate);
#endif
#endif /* defined(HIBERNATE_PRIVATE) */

#endif /* !defined(TOR_HIBERNATE_H) */

