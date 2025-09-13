/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file debug.h
 * \brief Macros for debugging our event-trace support.
 **/

#ifndef TOR_TRACE_DEBUG_H
#define TOR_TRACE_DEBUG_H

#ifdef USE_TRACING_INSTRUMENTATION_LOG_DEBUG

#include "lib/log/log.h"

/* Stringify pre-processor trick. */
#define XSTR(d) STR(d)
#define STR(s) #s

/* Send every event to a debug log level. This is useful to debug new trace
 * events without implementing them for a specific event tracing framework.
 *
 * NOTE: arguments can't be used because there is no easy generic ways to learn
 * their type and amount. It is probably doable with massive C pre-processor
 * trickery but this is meant to be simple. */

#define TOR_TRACE_LOG_DEBUG(subsystem, event_name, ...)             \
  log_debug(LD_GENERAL, "Tracepoint \"" XSTR(event_name) "\" from " \
                        "subsystem \"" XSTR(subsystem) "\" hit.")

#else /* !defined(USE_TRACING_INSTRUMENTATION_LOG_DEBUG) */

/* NOP the debug event. */
#define TOR_TRACE_LOG_DEBUG(subsystem, name, ...)

#endif /* defined(USE_TRACING_INSTRUMENTATION_LOG_DEBUG) */

#endif /* !defined(TOR_TRACE_DEBUG_H) */
