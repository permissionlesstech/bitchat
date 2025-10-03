/* Copyright (c) 2020, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file lttng.h
 * \brief Header file for lttng.c.
 **/

#ifndef TOR_TRACE_LTTNG_LTTNG_H
#define TOR_TRACE_LTTNG_LTTNG_H

#ifdef USE_TRACING_INSTRUMENTATION_LTTNG

#include <lttng/tracepoint.h>

/* Map event to an LTTng tracepoint. */
#define TOR_TRACE_LTTNG(subsystem, event_name, ...) \
  tracepoint(subsystem, event_name, ## __VA_ARGS__)

#else /* !defined(USE_TRACING_INSTRUMENTATION_LTTNG) */

/* NOP event. */
#define TOR_TRACE_LTTNG(subsystem, event_name, ...)

#endif /* !defined(USE_TRACING_INSTRUMENTATION_LTTNG) */

#endif /* TOR_TRACE_LTTNG_LTTNG_H */

