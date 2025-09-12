/* Copyright (c) 2011-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file procmon.h
 * \brief Headers for procmon.c
 **/

#ifndef TOR_PROCMON_H
#define TOR_PROCMON_H

#include "lib/evloop/compat_libevent.h"

#include "lib/log/log.h"

typedef struct tor_process_monitor_t tor_process_monitor_t;

/* DOCDOC tor_procmon_callback_t */
typedef void (*tor_procmon_callback_t)(void *);

int tor_validate_process_specifier(const char *process_spec,
                                   const char **msg);
tor_process_monitor_t *tor_process_monitor_new(struct event_base *base,
                                               const char *process_spec,
                                               log_domain_mask_t log_domain,
                                               tor_procmon_callback_t cb,
                                               void *cb_arg,
                                               const char **msg);
void tor_process_monitor_free_(tor_process_monitor_t *procmon);
#define tor_process_monitor_free(procmon) \
  FREE_AND_NULL(tor_process_monitor_t, tor_process_monitor_free_, (procmon))

#endif /* !defined(TOR_PROCMON_H) */

