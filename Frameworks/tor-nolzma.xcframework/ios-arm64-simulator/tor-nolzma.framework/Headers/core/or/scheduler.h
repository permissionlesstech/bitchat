/* * Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file scheduler.h
 * \brief Header file for scheduler*.c
 **/

#ifndef TOR_SCHEDULER_H
#define TOR_SCHEDULER_H

#include "core/or/or.h"
#include "core/or/channel.h"
#include "lib/testsupport/testsupport.h"

/** Scheduler type, we build an ordered list with those values from the
 * parsed strings in Schedulers. The reason to do such a thing is so we can
 * quickly and without parsing strings select the scheduler at anytime. */
typedef enum {
  SCHEDULER_NONE =     -1,
  SCHEDULER_VANILLA =   1,
  SCHEDULER_KIST =      2,
  SCHEDULER_KIST_LITE = 3,
} scheduler_types_t;

/**
 * A scheduler implementation is a collection of function pointers. If you
 * would like to add a new scheduler called foo, create scheduler_foo.c,
 * implement at least the mandatory ones, and implement get_foo_scheduler()
 * that returns a complete scheduler_t for your foo scheduler. See
 * scheduler_kist.c for an example.
 *
 * These function pointers SHOULD NOT be used anywhere outside of the
 * scheduling source files. The rest of Tor should communicate with the
 * scheduling system through the functions near the bottom of this file, and
 * those functions will call into the current scheduler implementation as
 * necessary.
 *
 * If your scheduler doesn't need to implement something (for example: it
 * doesn't create any state for itself, thus it has nothing to free when Tor
 * is shutting down), then set that function pointer to NULL.
 */
typedef struct scheduler_t {
  /* Scheduler type. This is used for logging when the scheduler is switched
   * during runtime. */
  scheduler_types_t type;

  /* (Optional) To be called when we want to prepare a scheduler for use.
   * Perhaps Tor just started and we are the lucky chosen scheduler, or
   * perhaps Tor is switching to this scheduler. No matter the case, this is
   * where we would prepare any state and initialize parameters. You might
   * think of this as the opposite of free_all(). */
  void (*init)(void);

  /* (Optional) To be called when we want to tell the scheduler to delete all
   * of its state (if any). Perhaps Tor is shutting down or perhaps we are
   * switching schedulers. */
  void (*free_all)(void);

  /* (Mandatory) Libevent controls the main event loop in Tor, and this is
   * where we register with libevent the next execution of run_sched_ev [which
   * ultimately calls run()]. */
  void (*schedule)(void);

  /* (Mandatory) This is the heart of a scheduler! This is where the
   * excitement happens! Here libevent has given us the chance to execute, and
   * we should do whatever we need to do in order to move some cells from
   * their circuit queues to output buffers in an intelligent manner. We
   * should do this quickly. When we are done, we'll try to schedule() ourself
   * if more work needs to be done to setup the next scheduling run. */
  void (*run)(void);

  /*
   * External event not related to the scheduler but that can influence it.
   */

  /* (Optional) To be called whenever Tor finds out about a new consensus.
   * First the scheduling system as a whole will react to the new consensus
   * and change the scheduler if needed. After that, the current scheduler
   * (which might be new) will call this so it has the chance to react to the
   * new consensus too. If there's a consensus parameter that your scheduler
   * wants to keep an eye on, this is where you should check for it.  */
  void (*on_new_consensus)(void);

  /* (Optional) To be called when a channel is being freed. Sometimes channels
   * go away (for example: the relay on the other end is shutting down). If
   * the scheduler keeps any channel-specific state and has memory to free
   * when channels go away, implement this and free it here. */
  void (*on_channel_free)(const channel_t *);

  /* (Optional) To be called whenever Tor is reloading configuration options.
   * For example: SIGHUP was issued and Tor is rereading its torrc. A
   * scheduler should use this as an opportunity to parse and cache torrc
   * options so that it doesn't have to call get_options() all the time. */
  void (*on_new_options)(void);
} scheduler_t;

/*****************************************************************************
 * Globally visible scheduler variables/values
 *
 * These are variables/constants that all of Tor should be able to see.
 *****************************************************************************/

/* Default interval that KIST runs (in ms). */
#define KIST_SCHED_RUN_INTERVAL_DEFAULT 2
/* Minimum interval that KIST runs. */
#define KIST_SCHED_RUN_INTERVAL_MIN 2
/* Maximum interval that KIST runs (in ms). */
#define KIST_SCHED_RUN_INTERVAL_MAX 100

/*****************************************************************************
 * Globally visible scheduler functions
 *
 * These functions are how the rest of Tor communicates with the scheduling
 * system.
 *****************************************************************************/

void scheduler_init(void);
void scheduler_free_all(void);
void scheduler_conf_changed(void);
void scheduler_notify_networkstatus_changed(void);
MOCK_DECL(void, scheduler_release_channel, (channel_t *chan));

/*
 * Ways for a channel to interact with the scheduling system. A channel only
 * really knows (i) whether or not it has cells it wants to send, and
 * (ii) whether or not it would like to write.
 */
void scheduler_channel_wants_writes(channel_t *chan);
MOCK_DECL(void, scheduler_channel_doesnt_want_writes, (channel_t *chan));
MOCK_DECL(void, scheduler_channel_has_waiting_cells, (channel_t *chan));

/*****************************************************************************
 * Private scheduler functions
 *
 * These functions are only visible to the scheduling system, the current
 * scheduler implementation, and tests.
 *****************************************************************************/
#ifdef SCHEDULER_PRIVATE

#include "ext/ht.h"

/*********************************
 * Defined in scheduler.c
 *********************************/

void scheduler_set_channel_state(channel_t *chan, int new_state);
const char *get_scheduler_state_string(int scheduler_state);

/* Triggers a BUG() and extra information with chan if available. */
#define SCHED_BUG(cond, chan) \
  (PREDICT_UNLIKELY(cond) ? \
   ((BUG(cond)) ? (scheduler_bug_occurred(chan), 1) : 0) : 0)

void scheduler_bug_occurred(const channel_t *chan);

smartlist_t *get_channels_pending(void);
MOCK_DECL(int, scheduler_compare_channels,
          (const void *c1_v, const void *c2_v));
void scheduler_ev_active(void);
void scheduler_ev_add(const struct timeval *next_run);

#ifdef TOR_UNIT_TESTS
extern smartlist_t *channels_pending;
extern struct mainloop_event_t *run_sched_ev;
extern const scheduler_t *the_scheduler;
void scheduler_touch_channel(channel_t *chan);
#endif /* defined(TOR_UNIT_TESTS) */

/*********************************
 * Defined in scheduler_kist.c
 *********************************/

#ifdef SCHEDULER_KIST_PRIVATE

/* Socket table entry which holds information of a channel's socket and kernel
 * TCP information. Only used by KIST. */
typedef struct socket_table_ent_t {
  HT_ENTRY(socket_table_ent_t) node;
  const channel_t *chan;
  /* Amount written this scheduling run */
  uint64_t written;
  /* Amount that can be written this scheduling run */
  uint64_t limit;
  /* TCP info from the kernel */
  uint32_t cwnd;
  uint32_t unacked;
  uint32_t mss;
  uint32_t notsent;
} socket_table_ent_t;

typedef HT_HEAD(outbuf_table_s, outbuf_table_ent_t) outbuf_table_t;

MOCK_DECL(int, channel_should_write_to_kernel,
          (outbuf_table_t *table, channel_t *chan));
MOCK_DECL(void, channel_write_to_kernel, (channel_t *chan));
MOCK_DECL(void, update_socket_info_impl, (socket_table_ent_t *ent));

int scheduler_can_use_kist(void);
void scheduler_kist_set_full_mode(void);
void scheduler_kist_set_lite_mode(void);
scheduler_t *get_kist_scheduler(void);
int kist_scheduler_run_interval(void);

#ifdef TOR_UNIT_TESTS
extern int32_t sched_run_interval;
#endif /* TOR_UNIT_TESTS */

#endif /* defined(SCHEDULER_KIST_PRIVATE) */

/*********************************
 * Defined in scheduler_vanilla.c
 *********************************/

scheduler_t *get_vanilla_scheduler(void);

#endif /* defined(SCHEDULER_PRIVATE) */

#endif /* !defined(TOR_SCHEDULER_H) */
