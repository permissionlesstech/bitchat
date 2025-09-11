/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file trace.h
 * \brief Header for trace.c
 **/

#ifndef TOR_LIB_TRACE_TRACE_H
#define TOR_LIB_TRACE_TRACE_H

#include "orconfig.h"

void tor_trace_init(void);
void tor_trace_free_all(void);

#ifdef HAVE_TRACING

#include "lib/log/log.h"

static inline void
tracing_log_warning(void)
{
  log_warn(LD_GENERAL,
           "Tracing capabilities have been built in. If this is NOT on "
           "purpose, your tor is NOT safe to run.");
}

#else /* !defined(HAVE_TRACING) */

/* NOP it. */
#define tracing_log_warning()

#endif /* defined(HAVE_TRACING) */

#endif /* !defined(TOR_LIB_TRACE_TRACE_H) */
