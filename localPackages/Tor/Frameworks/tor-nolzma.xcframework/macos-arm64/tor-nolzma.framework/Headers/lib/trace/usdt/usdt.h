/* Copyright (c) 2020, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file trace.h
 * \brief Header for usdt.h
 **/

#ifndef TOR_TRACE_USDT_USDT_H
#define TOR_TRACE_USDT_USDT_H

#ifdef USE_TRACING_INSTRUMENTATION_USDT

#ifdef HAVE_SYS_SDT_H
#define SDT_USE_VARIADIC
#include <sys/sdt.h>
#define TOR_STAP_PROBEV STAP_PROBEV
#else /* defined(HAVE_SYS_SDT_H) */
#define TOR_STAP_PROBEV(...)
#endif

/* Map events to an USDT probe. */
#define TOR_TRACE_USDT(subsystem, event_name, ...) \
  TOR_STAP_PROBEV(subsystem, event_name, ## __VA_ARGS__);

#else /* !defined(USE_TRACING_INSTRUMENTATION_USDT) */

/* NOP event. */
#define TOR_TRACE_USDT(subsystem, event_name, ...)

#endif /* !defined(USE_TRACING_INSTRUMENTATION_USDT) */

#endif /* !defined(TOR_TRACE_USDT_USDT_H) */
