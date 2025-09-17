/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file timers.h
 * \brief Header for timers.c
 **/

#ifndef TOR_TIMERS_H
#define TOR_TIMERS_H

#include "orconfig.h"
#include "lib/testsupport/testsupport.h"

struct monotime_t;
struct timeval;
typedef struct timeout tor_timer_t;
typedef void (*timer_cb_fn_t)(tor_timer_t *, void *,
                              const struct monotime_t *);
tor_timer_t *timer_new(timer_cb_fn_t cb, void *arg);
void timer_set_cb(tor_timer_t *t, timer_cb_fn_t cb, void *arg);
void timer_get_cb(const tor_timer_t *t,
                  timer_cb_fn_t *cb_out, void **arg_out);
void timer_schedule(tor_timer_t *t, const struct timeval *delay);
void timer_disable(tor_timer_t *t);
void timer_free_(tor_timer_t *t);
#define timer_free(t) FREE_AND_NULL(tor_timer_t, timer_free_, (t))

void timers_initialize(void);
void timers_shutdown(void);

#ifdef TOR_TIMERS_PRIVATE
STATIC void timers_run_pending(void);
#endif

#endif /* !defined(TOR_TIMERS_H) */
