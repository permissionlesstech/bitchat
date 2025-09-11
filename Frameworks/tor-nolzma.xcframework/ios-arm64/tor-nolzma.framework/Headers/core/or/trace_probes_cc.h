/* Copyright (c) 2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file trace_probes_cc.c
 * \brief The tracing probes for the congestion control subsystem.
 *        Currently, only LTTng-UST probes are available.
 **/

#ifndef TOR_TRACE_PROBES_CC_H
#define TOR_TRACE_PROBES_CC_H

#include "lib/trace/events.h"

/* We only build the following if LTTng instrumentation has been enabled. */
#ifdef USE_TRACING_INSTRUMENTATION_LTTNG

#include "core/or/lttng_cc.inc"

#endif /* USE_TRACING_INSTRUMENTATION_LTTNG */

#endif /* !defined(TOR_TRACE_PROBES_CC_H) */
