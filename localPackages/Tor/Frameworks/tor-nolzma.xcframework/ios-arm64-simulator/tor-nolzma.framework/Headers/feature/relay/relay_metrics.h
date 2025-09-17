/* Copyright (c) 2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file relay_metrics.h
 * @brief Header for feature/relay/relay_metrics.c
 **/

#ifndef TOR_FEATURE_RELAY_RELAY_METRICS_H
#define TOR_FEATURE_RELAY_RELAY_METRICS_H

#include "lib/container/smartlist.h"
#include "lib/metrics/metrics_common.h"

/** Metrics key for each reported metrics. This key is also used as an index in
 * the base_metrics array. */
typedef enum {
  /** Number of OOM invocation. */
  RELAY_METRICS_NUM_OOM_BYTES,
  /** Number of onionskines handled. */
  RELAY_METRICS_NUM_ONIONSKINS,
  /** Number of sockets. */
  RELAY_METRICS_NUM_SOCKETS,
  /** Number of global connection rate limit. */
  RELAY_METRICS_NUM_GLOBAL_RW_LIMIT,
  /** Number of DNS queries. */
  RELAY_METRICS_NUM_DNS,
  /** Number of DNS query errors. */
  RELAY_METRICS_NUM_DNS_ERRORS,
  /** Number of TCP exhaustion reached. */
  RELAY_METRICS_NUM_TCP_EXHAUSTION,
  /** Connections counters (always going up). */
  RELAY_METRICS_CONN_COUNTERS,
  /** Connections gauges. */
  RELAY_METRICS_CONN_GAUGES,
  /** Number of streams. */
  RELAY_METRICS_NUM_STREAMS,
  /** Congestion control counters. */
  RELAY_METRICS_CC_COUNTERS,
  /** Congestion control gauges. */
  RELAY_METRICS_CC_GAUGES,
  /** Denial of Service defenses subsystem. */
  RELAY_METRICS_NUM_DOS,
  /** Denial of Service defenses subsystem. */
  RELAY_METRICS_NUM_TRAFFIC,
  /** Relay flags. */
  RELAY_METRICS_RELAY_FLAGS,
  /** Numer of circuits. */
  RELAY_METRICS_NUM_CIRCUITS,
  /** Timestamp at which the current online keys will expire. */
  RELAY_METRICS_SIGNING_CERT_EXPIRY,
  /** Number of times we received an EST_REND cell */
  RELAY_METRICS_NUM_EST_REND,
  /** Number of times we received an EST_INTRO cell */
  RELAY_METRICS_NUM_EST_INTRO,
  /** Number of times we received an INTRO1 cell */
  RELAY_METRICS_NUM_INTRO1_CELLS,
  /** Number of times we received a REND1 cell */
  RELAY_METRICS_NUM_REND1_CELLS,
} relay_metrics_key_t;

/** The metadata of a relay metric. */
typedef struct relay_metrics_entry_t {
  /* Metric key used as a static array index. */
  relay_metrics_key_t key;
  /* Metric type. */
  metrics_type_t type;
  /* Metrics output name. */
  const char *name;
  /* Metrics output help comment. */
  const char *help;
  /* Update value function. */
  void (*fill_fn)(void);
} relay_metrics_entry_t;

/* Init. */
void relay_metrics_init(void);
void relay_metrics_free(void);

/* Accessors. */
const smartlist_t *relay_metrics_get_stores(void);

typedef enum {
  EST_INTRO_SUCCESS,
  EST_INTRO_MALFORMED,
  EST_INTRO_UNSUITABLE_CIRCUIT,
  EST_INTRO_CIRCUIT_DEAD,

  EST_INTRO_ACTION_COUNT
} est_intro_action_t;

void relay_increment_est_intro_action(est_intro_action_t);

typedef enum {
  EST_REND_SUCCESS,
  EST_REND_UNSUITABLE_CIRCUIT,
  EST_REND_SINGLE_HOP,
  EST_REND_MALFORMED,
  EST_REND_DUPLICATE_COOKIE,
  EST_REND_CIRCUIT_DEAD,

  EST_REND_ACTION_COUNT
} est_rend_action_t;

void relay_increment_est_rend_action(est_rend_action_t);

typedef enum {
  INTRO1_SUCCESS,
  INTRO1_CIRCUIT_DEAD,
  INTRO1_MALFORMED,
  INTRO1_UNKNOWN_SERVICE,
  INTRO1_RATE_LIMITED,
  INTRO1_CIRCUIT_REUSED,
  INTRO1_SINGLE_HOP,

  INTRO1_ACTION_COUNT
} intro1_action_t;

void relay_increment_intro1_action(intro1_action_t);

typedef enum {
  REND1_SUCCESS,
  REND1_UNSUITABLE_CIRCUIT,
  REND1_MALFORMED,
  REND1_UNKNOWN_COOKIE,
  REND1_CIRCUIT_DEAD,

  REND1_ACTION_COUNT
} rend1_action_t;

void relay_increment_rend1_action(rend1_action_t);

#endif /* !defined(TOR_FEATURE_RELAY_RELAY_METRICS_H) */
