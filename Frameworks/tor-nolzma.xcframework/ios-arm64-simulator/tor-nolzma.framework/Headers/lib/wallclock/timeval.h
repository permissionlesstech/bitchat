/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file timeval.h
 *
 * \brief Declarations for timeval-related macros that some platforms
 * are missing.
 **/

#ifndef TOR_TIMEVAL_H
#define TOR_TIMEVAL_H

#include "orconfig.h"
#include "lib/cc/torint.h"

#ifdef HAVE_SYS_TIME_H
#include <sys/time.h>
#endif

#ifdef TOR_COVERAGE
/* For coverage builds, we use a slower definition of these macros without
 * branches, to make coverage consistent. */
#undef timeradd
#undef timersub
#define timeradd(tv1,tv2,tvout) \
  do {                          \
    (tvout)->tv_sec = (tv1)->tv_sec + (tv2)->tv_sec;    \
    (tvout)->tv_usec = (tv1)->tv_usec + (tv2)->tv_usec; \
    (tvout)->tv_sec += (tvout)->tv_usec / 1000000;      \
    (tvout)->tv_usec %= 1000000;                        \
  } while (0)
#define timersub(tv1,tv2,tvout) \
  do {                          \
    (tvout)->tv_sec = (tv1)->tv_sec - (tv2)->tv_sec - 1;            \
    (tvout)->tv_usec = (tv1)->tv_usec - (tv2)->tv_usec + 1000000;   \
    (tvout)->tv_sec += (tvout)->tv_usec / 1000000;                  \
    (tvout)->tv_usec %= 1000000;                                    \
  } while (0)
#endif /* defined(TOR_COVERAGE) */

#ifndef timeradd
/** Replacement for timeradd on platforms that do not have it: sets tvout to
 * the sum of tv1 and tv2. */
#define timeradd(tv1,tv2,tvout) \
  do {                                                  \
    (tvout)->tv_sec = (tv1)->tv_sec + (tv2)->tv_sec;    \
    (tvout)->tv_usec = (tv1)->tv_usec + (tv2)->tv_usec; \
    if ((tvout)->tv_usec >= 1000000) {                  \
      (tvout)->tv_usec -= 1000000;                      \
      (tvout)->tv_sec++;                                \
    }                                                   \
  } while (0)
#endif /* !defined(timeradd) */

#ifndef timersub
/** Replacement for timersub on platforms that do not have it: sets tvout to
 * tv1 minus tv2. */
#define timersub(tv1,tv2,tvout) \
  do {                                                  \
    (tvout)->tv_sec = (tv1)->tv_sec - (tv2)->tv_sec;    \
    (tvout)->tv_usec = (tv1)->tv_usec - (tv2)->tv_usec; \
    if ((tvout)->tv_usec < 0) {                         \
      (tvout)->tv_usec += 1000000;                      \
      (tvout)->tv_sec--;                                \
    }                                                   \
  } while (0)
#endif /* !defined(timersub) */

#ifndef COCCI
#ifndef timercmp
/** Replacement for timercmp on platforms that do not have it: returns true
 * iff the relational operator "op" makes the expression tv1 op tv2 true.
 *
 * Note that while this definition should work for all boolean operators, some
 * platforms' native timercmp definitions do not support >=, <=, or ==.  So
 * don't use those.
 */
#define timercmp(tv1,tv2,op)                    \
  (((tv1)->tv_sec == (tv2)->tv_sec) ?           \
   ((tv1)->tv_usec op (tv2)->tv_usec) :         \
   ((tv1)->tv_sec op (tv2)->tv_sec))
#endif /* !defined(timercmp) */
#endif /* !defined(COCCI) */

#endif /* !defined(TOR_TIMEVAL_H) */
