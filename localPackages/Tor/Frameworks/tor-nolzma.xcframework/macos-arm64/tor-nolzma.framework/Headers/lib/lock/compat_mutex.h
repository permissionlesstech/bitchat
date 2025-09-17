/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compat_mutex.h
 *
 * \brief Header for compat_mutex.c
 **/

#ifndef TOR_COMPAT_MUTEX_H
#define TOR_COMPAT_MUTEX_H

#include "orconfig.h"
#include "lib/cc/torint.h"
#include "lib/malloc/malloc.h"

#if defined(HAVE_PTHREAD_H) && !defined(_WIN32)
#include <pthread.h>
#endif

#if defined(_WIN32)
#include <windows.h>
#endif

#if defined(_WIN32)
#define USE_WIN32_THREADS
#elif defined(HAVE_PTHREAD_H) && defined(HAVE_PTHREAD_CREATE)
#define USE_PTHREADS
#else
#error "No threading system was found"
#endif /* defined(_WIN32) || ... */

/* Because we use threads instead of processes on most platforms (Windows,
 * Linux, etc), we need locking for them.  On platforms with poor thread
 * support or broken gethostbyname_r, these functions are no-ops. */

/** A generic lock structure for multithreaded builds. */
typedef struct tor_mutex_t {
#if defined(USE_WIN32_THREADS)
  /** Windows-only: on windows, we implement locks with SRW locks. */
  SRWLOCK mutex;
  /** For recursive lock support (SRW locks are not recursive) */
  enum mutex_type_t {
    NON_RECURSIVE = 0,
    RECURSIVE
  } type;
  LONG lock_owner; // id of the thread that owns the lock
  int lock_count; // number of times the lock is held recursively
#elif defined(USE_PTHREADS)
  /** Pthreads-only: with pthreads, we implement locks with
   * pthread_mutex_t. */
  pthread_mutex_t mutex;
#else
  /** No-threads only: Dummy variable so that tor_mutex_t takes up space. */
  int _unused;
#endif /* defined(USE_WIN32_THREADS) || ... */
} tor_mutex_t;

tor_mutex_t *tor_mutex_new(void);
tor_mutex_t *tor_mutex_new_nonrecursive(void);
void tor_mutex_init(tor_mutex_t *m);
void tor_mutex_init_nonrecursive(tor_mutex_t *m);
void tor_mutex_acquire(tor_mutex_t *m);
void tor_mutex_release(tor_mutex_t *m);
void tor_mutex_free_(tor_mutex_t *m);
/**
 * @copydoc tor_mutex_free_
 *
 * Additionally, set the pointer <b>m</b> to NULL.
 **/
#define tor_mutex_free(m) FREE_AND_NULL(tor_mutex_t, tor_mutex_free_, (m))
void tor_mutex_uninit(tor_mutex_t *m);

void tor_locking_init(void);

#endif /* !defined(TOR_COMPAT_MUTEX_H) */
