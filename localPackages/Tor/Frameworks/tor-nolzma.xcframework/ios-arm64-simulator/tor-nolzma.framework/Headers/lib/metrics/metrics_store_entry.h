/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file metrics_store_entry.h
 * @brief Header for lib/metrics/metrics_store_entry.c
 **/

#ifndef TOR_LIB_METRICS_METRICS_STORE_ENTRY_H
#define TOR_LIB_METRICS_METRICS_STORE_ENTRY_H

#include "lib/cc/torint.h"

#include "lib/metrics/metrics_common.h"
#include "lib/container/smartlist.h"

#ifdef METRICS_STORE_ENTRY_PRIVATE

/** Metrics store entry. They reside in a metrics_store_t object and are
 * opaque to the outside world. */
struct metrics_store_entry_t {
  /** Type of entry. */
  metrics_type_t type;

  /** Name. */
  char *name;

  /** Help comment string. */
  char *help;

  /** Labels attached to that entry. If NULL, no labels.
   *
   * Labels are used to add extra context to a metrics. For example, a label
   * could be an onion address so the metrics can be differentiate. */
  smartlist_t *labels;

  /* Actual data. */
  union {
    metrics_counter_t counter;
    metrics_gauge_t gauge;
    metrics_histogram_t histogram;
  } u;
};

#endif /* defined(METRICS_STORE_ENTRY_PRIVATE) */

typedef struct metrics_store_entry_t metrics_store_entry_t;

/* Allocators. */
metrics_store_entry_t *metrics_store_entry_new(const metrics_type_t type,
                                               const char *name,
                                               const char *help,
                                               size_t bucket_count,
                                               const int64_t *buckets);

void metrics_store_entry_free_(metrics_store_entry_t *entry);
#define metrics_store_entry_free(entry) \
  FREE_AND_NULL(metrics_store_entry_t, metrics_store_entry_free_, (entry));

/* Accessors. */
int64_t metrics_store_entry_get_value(const metrics_store_entry_t *entry);
uint64_t metrics_store_hist_entry_get_value(const metrics_store_entry_t *entry,
                                           const int64_t bucket);
bool metrics_store_entry_has_label(const metrics_store_entry_t *entry,
                                   const char *label);
metrics_store_entry_t *metrics_store_find_entry_with_label(
        const smartlist_t *entries, const char *label);
bool metrics_store_entry_is_histogram(const metrics_store_entry_t *entry);
uint64_t metrics_store_hist_entry_get_count(
        const metrics_store_entry_t *entry);
int64_t metrics_store_hist_entry_get_sum(const metrics_store_entry_t *entry);

/* Modifiers. */
void metrics_store_entry_add_label(metrics_store_entry_t *entry,
                                   const char *label);
void metrics_store_entry_reset(metrics_store_entry_t *entry);
void metrics_store_entry_update(metrics_store_entry_t *entry,
                                const int64_t value);
void metrics_store_hist_entry_update(metrics_store_entry_t *entry,
                                const int64_t value, const int64_t obs);

#endif /* !defined(TOR_LIB_METRICS_METRICS_STORE_ENTRY_H) */
