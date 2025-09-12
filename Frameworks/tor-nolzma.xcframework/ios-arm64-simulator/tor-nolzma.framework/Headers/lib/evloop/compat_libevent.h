/* Copyright (c) 2009-2024, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compat_libevent.h
 * \brief Header for compat_libevent.c
 **/

#ifndef TOR_COMPAT_LIBEVENT_H
#define TOR_COMPAT_LIBEVENT_H

#include "orconfig.h"
#include "lib/testsupport/testsupport.h"
#include "lib/malloc/malloc.h"

#include <stdbool.h>

void configure_libevent_logging(void);
void suppress_libevent_log_msg(const char *msg);

#define tor_event_new     event_new
#define tor_event_del     event_del
#define tor_evtimer_new   evtimer_new
#define tor_evsignal_new  evsignal_new
#define tor_evdns_add_server_port(sock, tcp, cb, data) \
  evdns_add_server_port_with_base(tor_libevent_get_base(), \
  (sock),(tcp),(cb),(data));

struct event;
struct event_base;
struct timeval;

void tor_event_free_(struct event *ev);
#define tor_event_free(ev) \
  FREE_AND_NULL(struct event, tor_event_free_, (ev))

typedef struct periodic_timer_t periodic_timer_t;

periodic_timer_t *periodic_timer_new(struct event_base *base,
             const struct timeval *tv,
             void (*cb)(periodic_timer_t *timer, void *data),
             void *data);
void periodic_timer_free_(periodic_timer_t *);
void periodic_timer_launch(periodic_timer_t *, const struct timeval *tv);
void periodic_timer_disable(periodic_timer_t *);
#define periodic_timer_free(t) \
  FREE_AND_NULL(periodic_timer_t, periodic_timer_free_, (t))

typedef struct mainloop_event_t mainloop_event_t;
mainloop_event_t *mainloop_event_new(void (*cb)(mainloop_event_t *, void *),
                                     void *userdata);
mainloop_event_t * mainloop_event_postloop_new(
                                     void (*cb)(mainloop_event_t *, void *),
                                     void *userdata);
void mainloop_event_activate(mainloop_event_t *event);
int mainloop_event_schedule(mainloop_event_t *event,
                            const struct timeval *delay);
void mainloop_event_cancel(mainloop_event_t *event);
void mainloop_event_free_(mainloop_event_t *event);
#define mainloop_event_free(event) \
  FREE_AND_NULL(mainloop_event_t, mainloop_event_free_, (event))

/** Defines a configuration for using libevent with Tor: passed as an argument
 * to tor_libevent_initialize() to describe how we want to set up. */
typedef struct tor_libevent_cfg_t {
  /** How many CPUs should we use (not currently useful). */
  int num_cpus;
  /** How many milliseconds should we allow between updating bandwidth limits?
   * (Not currently useful). */
  int msec_per_tick;
} tor_libevent_cfg_t;

void tor_libevent_initialize(tor_libevent_cfg_t *cfg);
bool tor_libevent_is_initialized(void);
MOCK_DECL(struct event_base *, tor_libevent_get_base, (void));
const char *tor_libevent_get_method(void);
void tor_check_libevent_header_compatibility(void);
const char *tor_libevent_get_version_str(void);
const char *tor_libevent_get_header_version_str(void);
void tor_libevent_free_all(void);

int tor_init_libevent_rng(void);

#ifdef TOR_UNIT_TESTS
void tor_libevent_postfork(void);
#endif

int tor_libevent_run_event_loop(struct event_base *base, int once);
void tor_libevent_exit_loop_after_delay(struct event_base *base,
                                        const struct timeval *delay);
void tor_libevent_exit_loop_after_callback(struct event_base *base);

#ifdef COMPAT_LIBEVENT_PRIVATE

/** Macro: returns the number of a Libevent version as a 4-byte number,
    with the first three bytes representing the major, minor, and patchlevel
    respectively of the library.  The fourth byte is unused.

    This is equivalent to the format of LIBEVENT_VERSION_NUMBER on Libevent
    2.0.1 or later. */
#define V(major, minor, patch) \
  (((major) << 24) | ((minor) << 16) | ((patch) << 8))

STATIC void
libevent_logging_callback(int severity, const char *msg);
#endif /* defined(COMPAT_LIBEVENT_PRIVATE) */

#endif /* !defined(TOR_COMPAT_LIBEVENT_H) */
