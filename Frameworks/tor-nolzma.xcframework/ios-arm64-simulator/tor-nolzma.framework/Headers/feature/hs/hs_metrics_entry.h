/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file hs_metrics_entry.h
 * @brief Header for feature/hs/hs_metrics_entry.c
 **/

#ifndef TOR_FEATURE_HS_METRICS_ENTRY_H
#define TOR_FEATURE_HS_METRICS_ENTRY_H

#ifdef HS_METRICS_ENTRY_PRIVATE

#include "lib/metrics/metrics_common.h"

/* Possible values for the reason label of the
 * hs_intro_rejected_intro_req_count metric. */
/** The hidden service received an unknown introduction auth key. */
#define HS_METRICS_ERR_INTRO_REQ_BAD_AUTH_KEY      "bad_auth_key"
/** The hidden service received a malformed INTRODUCE2 cell. */
#define HS_METRICS_ERR_INTRO_REQ_INTRODUCE2        "invalid_introduce2"
/** The hidden service does not have the necessary subcredential. */
#define HS_METRICS_ERR_INTRO_REQ_SUBCREDENTIAL     "subcredential"
/** The hidden service received an INTRODUCE2 replay. */
#define HS_METRICS_ERR_INTRO_REQ_INTRODUCE2_REPLAY "replay"

/* Possible values for the reason label of the hs_rdv_error_count metric. */
/** The hidden service failed to connect to the rendezvous point. */
#define HS_METRICS_ERR_RDV_RP_CONN_FAILURE         "rp_conn_failure"
/** The hidden service failed to build a circuit to the rendezvous point due
 * to an invalid selected path. */
#define  HS_METRICS_ERR_RDV_PATH                   "invalid_path"
/** The hidden service failed to send the RENDEZVOUS1 cell on rendezvous
 * circuit. */
#define HS_METRICS_ERR_RDV_RENDEZVOUS1             "rendezvous1"
/** The hidden service failed to set up an end-to-end rendezvous circuit to
 * the client. */
#define HS_METRICS_ERR_RDV_E2E                     "e2e_circ"
/** The hidden service reattempted to connect to the rendezvous point by
 * launching a new circuit to it, but failed */
#define HS_METRICS_ERR_RDV_RETRY                   "retry"

/** Metrics key which are used as an index in the main base metrics array. */
typedef enum {
  /** Number of introduction requests. */
  HS_METRICS_NUM_INTRODUCTIONS = 0,
  /** Number of bytes written from onion service to application. */
  HS_METRICS_APP_WRITE_BYTES = 1,
  /** Number of bytes read from application to onion service. */
  HS_METRICS_APP_READ_BYTES = 2,
  /** Number of established rendezvous. */
  HS_METRICS_NUM_ESTABLISHED_RDV = 3,
  /** Number of rendezvous circuits created. */
  HS_METRICS_NUM_RDV = 4,
  /** Number of failed rendezvous. */
  HS_METRICS_NUM_FAILED_RDV = 5,
  /** Number of established introducton points. */
  HS_METRICS_NUM_ESTABLISHED_INTRO = 6,
  /** Number of rejected introducton requests. */
  HS_METRICS_NUM_REJECTED_INTRO_REQ = 7,
  /** Introduction circuit build time in milliseconds. */
  HS_METRICS_INTRO_CIRC_BUILD_TIME = 8,
  /** Rendezvous circuit build time in milliseconds. */
  HS_METRICS_REND_CIRC_BUILD_TIME = 9,
  /** Number of requests waiting in the proof of work priority queue. */
  HS_METRICS_POW_NUM_PQUEUE_RDV = 10,
  /** Suggested effort for requests with a proof of work client puzzle. */
  HS_METRICS_POW_SUGGESTED_EFFORT = 11,
} hs_metrics_key_t;

/** The metadata of an HS metrics. */
typedef struct hs_metrics_entry_t {
  /* Metric key used as a static array index. */
  hs_metrics_key_t key;
  /* Metric type. */
  metrics_type_t type;
  /* Metrics output name. */
  const char *name;
  /* Metrics output help comment. */
  const char *help;
  /* The buckets, if the metric type is METRICS_TYPE_HISTOGRAM. */
  const int64_t *buckets;
  /* The number of buckets, if the metric type is METRICS_TYPE_HISTOGRAM. */
  size_t bucket_count;
  /* True iff a port label should be added to the metrics entry. */
  bool port_as_label;
} hs_metrics_entry_t;

extern const hs_metrics_entry_t base_metrics[];
extern const size_t base_metrics_size;

extern const char *hs_metrics_intro_req_error_reasons[];
extern const size_t hs_metrics_intro_req_error_reasons_size;

extern const char *hs_metrics_rend_error_reasons[];
extern const size_t hs_metrics_rend_error_reasons_size;

#endif /* defined(HS_METRICS_ENTRY_PRIVATE) */
#endif /* !defined(TOR_FEATURE_HS_METRICS_ENTRY_H) */
