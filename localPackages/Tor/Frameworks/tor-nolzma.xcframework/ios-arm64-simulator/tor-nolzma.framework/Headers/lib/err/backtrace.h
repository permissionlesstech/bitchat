/* Copyright (c) 2013-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_BACKTRACE_H
#define TOR_BACKTRACE_H

/**
 * \file backtrace.h
 *
 * \brief Header for backtrace.c
 **/

#include "orconfig.h"
#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"
#include "lib/defs/logging_types.h"

typedef void (*tor_log_fn)(int, log_domain_mask_t, const char *fmt, ...)
  CHECK_PRINTF(3,4);

void log_backtrace_impl(int severity, log_domain_mask_t domain,
                        const char *msg,
                        tor_log_fn logger);
int configure_backtrace_handler(const char *tor_version);
void clean_up_backtrace_handler(void);
void dump_stack_symbols_to_error_fds(void);
const char *get_tor_backtrace_version(void);

#define log_backtrace(sev, dom, msg) \
  log_backtrace_impl((sev), (dom), (msg), tor_log)

#ifdef BACKTRACE_PRIVATE
#if defined(HAVE_EXECINFO_H) && defined(HAVE_BACKTRACE) && \
  defined(HAVE_BACKTRACE_SYMBOLS_FD) && defined(HAVE_SIGACTION)
void clean_backtrace(void **stack, size_t depth, const ucontext_t *ctx);
#endif
#endif /* defined(BACKTRACE_PRIVATE) */

#endif /* !defined(TOR_BACKTRACE_H) */
