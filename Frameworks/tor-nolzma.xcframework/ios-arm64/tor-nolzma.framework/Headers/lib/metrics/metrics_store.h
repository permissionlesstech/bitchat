/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file metrics_store.h
 * @brief Header for lib/metrics/metrics_store.c
 **/

#ifndef TOR_LIB_METRICS_METRICS_STORE_H
#define TOR_LIB_METRICS_METRICS_STORE_H

#include "lib/buf/buffers.h"
#include "lib/container/smartlist.h"

#include "lib/metrics/metrics_common.h"
#include "lib/metrics/metrics_store_entry.h"

/* Stub. */
typedef struct metrics_store_t metrics_store_t;

/* Allocators. */
void metrics_store_free_(metrics_store_t *store);
#define metrics_store_free(store) \
  FREE_AND_NULL(metrics_store_t, metrics_store_free_, (store))
metrics_store_t *metrics_store_new(void);

/* Modifiers. */
metrics_store_entry_t *metrics_store_add(metrics_store_t *store,
                                         metrics_type_t type, const char *name,
                                         const char *help, size_t bucket_count,
                                         const int64_t *buckets);

void metrics_store_reset(metrics_store_t *store);

/* Accessors. */
smartlist_t *metrics_store_get_all(const metrics_store_t *store,
                                   const char *name);
void metrics_store_get_output(const metrics_format_t fmt,
                              const metrics_store_t *store, buf_t *data);

#ifdef METRICS_METRICS_STORE_PRIVATE

#endif /* METRICS_METRICS_STORE_PRIVATE. */

#endif /* !defined(TOR_LIB_METRICS_METRICS_STORE_H) */
