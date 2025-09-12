/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file trace_probes_circuit.c
 * \brief The tracing probes for the circuit subsystem. Currently, only
 *        LTTng-UST probes are available.
 **/

#ifndef TOR_TRACE_PROBES_CIRCUIT_H
#define TOR_TRACE_PROBES_CIRCUIT_H

#include "lib/trace/events.h"

/* We only build the following if LTTng instrumentation has been enabled. */
#ifdef USE_TRACING_INSTRUMENTATION_LTTNG

#include "core/or/lttng_circuit.inc"

#endif /* USE_TRACING_INSTRUMENTATION_LTTNG */

#endif /* !defined(TOR_TRACE_PROBES_CIRCUIT_H) */
