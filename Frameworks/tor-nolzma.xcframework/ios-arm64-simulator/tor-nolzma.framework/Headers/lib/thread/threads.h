/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file threads.h
 * \brief Header for threads.c
 **/

#ifndef TOR_COMPAT_THREADS_H
#define TOR_COMPAT_THREADS_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"
#include "lib/lock/compat_mutex.h"

#if defined(HAVE_STDATOMIC_H) && defined(STDATOMIC_WORKS)
#define HAVE_WORKING_STDATOMIC
#endif

#ifdef HAVE_WORKING_STDATOMIC
#include <stdatomic.h>
#endif

struct timeval;

int spawn_func(void (*func)(void *), void *data);
void spawn_exit(void) ATTR_NORETURN;

unsigned long tor_get_thread_id(void);
void tor_threads_init(void);

/** Conditions need nonrecursive mutexes with pthreads. */
#define tor_mutex_init_for_cond(m) tor_mutex_init_nonrecursive(m)

void set_main_thread(void);
int in_main_thread(void);

typedef struct tor_cond_t {
#ifdef USE_PTHREADS
  pthread_cond_t cond;
#elif defined(USE_WIN32_THREADS)
  CONDITION_VARIABLE cond;
#else
#error no known condition implementation.
#endif /* defined(USE_PTHREADS) || ... */
} tor_cond_t;

tor_cond_t *tor_cond_new(void);
void tor_cond_free_(tor_cond_t *cond);
#define tor_cond_free(c) FREE_AND_NULL(tor_cond_t, tor_cond_free_, (c))
int tor_cond_init(tor_cond_t *cond);
void tor_cond_uninit(tor_cond_t *cond);
int tor_cond_wait(tor_cond_t *cond, tor_mutex_t *mutex,
                  const struct timeval *tv);
void tor_cond_signal_one(tor_cond_t *cond);
void tor_cond_signal_all(tor_cond_t *cond);

typedef struct tor_threadlocal_t {
#ifdef _WIN32
  DWORD index;
#else
  pthread_key_t key;
#endif
} tor_threadlocal_t;

/** Initialize a thread-local variable.
 *
 * After you call this function on a tor_threadlocal_t, you can call
 * tor_threadlocal_set to change the current value of this variable for the
 * current thread, and tor_threadlocal_get to retrieve the current value for
 * the current thread.  Each thread has its own value.
 **/
int tor_threadlocal_init(tor_threadlocal_t *threadlocal);
/**
 * Release all resource associated with a thread-local variable.
 */
void tor_threadlocal_destroy(tor_threadlocal_t *threadlocal);
/**
 * Return the current value of a thread-local variable for this thread.
 *
 * It's undefined behavior to use this function if the threadlocal hasn't
 * been initialized, or has been destroyed.
 */
void *tor_threadlocal_get(tor_threadlocal_t *threadlocal);
/**
 * Change the current value of a thread-local variable for this thread to
 * <b>value</b>.
 *
 * It's undefined behavior to use this function if the threadlocal hasn't
 * been initialized, or has been destroyed.
 */
void tor_threadlocal_set(tor_threadlocal_t *threadlocal, void *value);

/**
 * Atomic counter type; holds a size_t value.
 */
#ifdef HAVE_WORKING_STDATOMIC
typedef struct atomic_counter_t {
  atomic_size_t val;
} atomic_counter_t;
#ifndef COCCI
#define ATOMIC_LINKAGE static
#endif
#else /* !defined(HAVE_WORKING_STDATOMIC) */
typedef struct atomic_counter_t {
  tor_mutex_t mutex;
  size_t val;
} atomic_counter_t;
#define ATOMIC_LINKAGE
#endif /* defined(HAVE_WORKING_STDATOMIC) */

ATOMIC_LINKAGE void atomic_counter_init(atomic_counter_t *counter);
ATOMIC_LINKAGE void atomic_counter_destroy(atomic_counter_t *counter);
ATOMIC_LINKAGE void atomic_counter_add(atomic_counter_t *counter, size_t add);
ATOMIC_LINKAGE void atomic_counter_sub(atomic_counter_t *counter, size_t sub);
ATOMIC_LINKAGE size_t atomic_counter_get(atomic_counter_t *counter);
ATOMIC_LINKAGE size_t atomic_counter_exchange(atomic_counter_t *counter,
                                              size_t newval);
#undef ATOMIC_LINKAGE

#ifdef HAVE_WORKING_STDATOMIC
/** Initialize a new atomic counter with the value 0 */
static inline void
atomic_counter_init(atomic_counter_t *counter)
{
  atomic_init(&counter->val, 0);
}
/** Clean up all resources held by an atomic counter.
 *
 * This usage note applies to the compat_threads implementation of
 * atomic_counter_destroy():
 * Destroying a locked mutex is undefined behaviour. Global mutexes may be
 * locked when they are passed to this function, because multiple threads can
 * still access them. So we can either:
 *  - destroy on shutdown, and re-initialise when tor re-initialises, or
 *  - skip destroying and re-initialisation, using a sentinel variable.
 * See #31735 for details.
 */
static inline void
atomic_counter_destroy(atomic_counter_t *counter)
{
  (void)counter;
}
/** Add a value to an atomic counter. */
static inline void
atomic_counter_add(atomic_counter_t *counter, size_t add)
{
  (void) atomic_fetch_add(&counter->val, add);
}
/** Subtract a value from an atomic counter. */
static inline void
atomic_counter_sub(atomic_counter_t *counter, size_t sub)
{
  (void) atomic_fetch_sub(&counter->val, sub);
}
/** Return the current value of an atomic counter */
static inline size_t
atomic_counter_get(atomic_counter_t *counter)
{
  return atomic_load(&counter->val);
}
/** Replace the value of an atomic counter; return the old one. */
static inline size_t
atomic_counter_exchange(atomic_counter_t *counter, size_t newval)
{
  return atomic_exchange(&counter->val, newval);
}

#else /* !defined(HAVE_WORKING_STDATOMIC) */
#endif /* defined(HAVE_WORKING_STDATOMIC) */

#endif /* !defined(TOR_COMPAT_THREADS_H) */
