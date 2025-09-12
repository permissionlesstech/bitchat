/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file metrics_common.h
 * @brief Header for lib/metrics/metrics_common.c
 **/

#ifndef TOR_LIB_METRICS_METRICS_COMMON_H
#define TOR_LIB_METRICS_METRICS_COMMON_H

#include "lib/cc/torint.h"
#include "lib/container/smartlist.h"

/** Helper macro that must be used to construct the right namespaced metrics
 * name. A name is a string so stringify the result. */
#define METRICS_STR(val) #val
#define METRICS_NAME(name) METRICS_STR(tor_ ## name)

/** Format output type. */
typedef enum {
  /** Prometheus data output format. */
  METRICS_FORMAT_PROMETHEUS = 1,
} metrics_format_t;

/** Metric type. */
typedef enum {
  /* Increment only. */
  METRICS_TYPE_COUNTER,
  /* Can go up or down. */
  METRICS_TYPE_GAUGE,
  /* Cumulative counters for multiple observation buckets. */
  METRICS_TYPE_HISTOGRAM,
} metrics_type_t;

typedef struct metrics_histogram_bucket_t {
  /* The value of the counter of this bucket. */
  uint64_t value;
  /* Technically, this should be a floating point value, but in practice, we
   * can make do with integer buckets. */
  int64_t bucket;
} metrics_histogram_bucket_t;

/** Metric counter object (METRICS_TYPE_COUNTER). */
typedef struct metrics_counter_t {
  uint64_t value;
} metrics_counter_t;

/** Metric gauge object (METRICS_TYPE_GAUGE). */
typedef struct metrics_gauge_t {
  int64_t value;
} metrics_gauge_t;

/** Metric histogram object (METRICS_TYPE_HISTOGRAM). */
typedef struct metrics_histogram_t {
  /* The observation buckets. */
  metrics_histogram_bucket_t *buckets;
  /* The number of observation buckets. */
  size_t bucket_count;
  /* The sum of all observations */
  int64_t sum;
  /* The total number of observations */
  uint64_t count;
} metrics_histogram_t;

const char *metrics_type_to_str(const metrics_type_t type);

/* Helpers. */
const char *metrics_format_label(const char *key, const char *value);

#endif /* !defined(TOR_LIB_METRICS_METRICS_COMMON_H) */
