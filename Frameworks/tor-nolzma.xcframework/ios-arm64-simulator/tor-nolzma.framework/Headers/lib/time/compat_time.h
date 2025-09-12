/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compat_time.h
 *
 * \brief Functions and types for monotonic times.
 *
 * monotime_* functions try to provide a high-resolution monotonic timer with
 * something the best resolution the system provides.  monotime_coarse_*
 * functions run faster (if the operating system gives us a way to do that)
 * but produce a less accurate timer: accuracy will probably be on the order
 * of tens of milliseconds.
 */

/* Q: When should I use monotonic time?
 *
 * A: If you need a time that never decreases, use monotonic time. If you need
 * to send a time to a user or another process, or store a time, use the
 * wall-clock time.
 *
 * Q: Should you use monotime or monotime_coarse as your source?
 *
 * A: Generally, you get better precision with monotime, but better
 * performance with monotime_coarse.
 *
 * Q: What is a "monotonic" time, exactly?
 *
 * A: Monotonic times are strictly non-decreasing. The difference between any
 * previous monotonic time, and the current monotonic time, is always greater
 * than *or equal to* zero.
 * Zero deltas happen more often:
 *  - on Windows (due to an OS bug),
 *  - when using monotime_coarse, or on systems with low-resolution timers,
 *  - on platforms where we emulate monotonic time using wall-clock time, and
 *  - when using time units that are larger than nanoseconds (due to
 *    truncation on division).
 *
 * Q: Should you use monotime_t or monotime_coarse_t directly? Should you use
 *    usec? msec? "stamp units?"
 *
 * A: Using monotime_t and monotime_coarse_t directly is most time-efficient,
 * since no conversion needs to happen.  But they can potentially use more
 * memory than you would need for a usec/msec/"stamp unit" count.
 *
 * Converting to usec or msec on some platforms, and working with them in
 * general, creates a risk of doing a 64-bit division.  64-bit division is
 * expensive on 32-bit platforms, which still do exist.
 *
 * The "stamp unit" type is designed to give a type that is cheap to convert
 * from monotime_coarse, has resolution of about 1-2ms, and fits nicely in a
 * 32-bit integer.  Its downside is that it does not correspond directly
 * to a natural unit of time.
 *
 * There is not much point in using "coarse usec" or "coarse nsec", since the
 * current coarse monotime implementations give you on the order of
 * milliseconds of precision.
 *
 * Q: So, what backends is monotime_coarse using?
 *
 * A: Generally speaking, it uses "whatever monotonic-ish time implementation
 * does not require a context switch."  The various implementations provide
 * this by having a view of the current time in a read-only memory page that
 * is updated with a frequency corresponding to the kernel's tick count.
 *
 * On Windows, monotime_coarse uses GetCount64() [or GetTickCount() on
 * obsolete systems].  MSDN claims that the resolution is "typically in the
 * range of 10-16 msec", but it has said that for years.  Storing
 * monotime_coarse_t uses 8 bytes.
 *
 * On OSX/iOS, monotime_coarse uses uses mach_approximate_time() where
 * available, and falls back to regular monotime. The precision is not
 * documented, but the implementation is open-source: it reads from a page
 * that the kernel updates. Storing monotime_coarse_t uses 8 bytes.
 *
 * On unixy systems, monotime_coarse uses clock_gettime() with
 * CLOCK_MONOTONIC_COARSE where available, and falls back to CLOCK_MONOTONIC.
 * It typically uses vdso tricks to read from a page that the kernel updates.
 * Its precision fixed, but you can get it with clock_getres(): on my Linux
 * desktop, it claims to be 1 msec, but it will depend on the system HZ
 * setting. Storing monotime_coarse_t uses 16 bytes.
 *
 * [TODO: Try CLOCK_MONOTONIC_FAST on foobsd.]
 *
 * Q: What backends is regular monotonic time using?
 *
 * A: In general, regular monotime uses something that requires a system call.
 * On platforms where system calls are cheap, you win!  Otherwise, you lose.
 *
 *   XXX: This hasn't been true for a long time. Expect both coarse and fine
 *        monotime won't require a syscall, but they will have different
 *        costs in terms of low-level synchronization inside the vDSO and
 *        the hardware. The basic guidelines here still apply, but we aren't
 *        really worrying about system calls any more, and the integer div
 *        concerns are becoming nearly unimportant as well.
 *
 * On Windows, monotonic time uses QuereyPerformanceCounter.  Storing
 * monotime_t costs 8 bytes.
 *
 * On OSX/Apple, monotonic time uses mach_absolute_time.  Storing
 * monotime_t costs 8 bytes.
 *
 * On unixy systems, monotonic time uses CLOCK_MONOTONIC.  Storing
 * monotime_t costs 16 bytes.
 *
 * Q: Tell me about the costs of converting to a 64-bit nsec, usec, or msec
 *    count.
 *
 * A: Windows, coarse: Cheap, since it's all multiplication.
 *
 * Windows, precise: Expensive on 32-bit: it needs 64-bit division.
 *
 * Apple, all: Expensive on 32-bit: it needs 64-bit division.
 *
 * Unixy, all: Fairly cheap, since the only division required is dividing
 * tv_nsec 1000, and nanoseconds-per-second fits in a 32-bit value.
 *
 * All, "timestamp units": Cheap everywhere: it never divides.
 *
 * Q: This is only somewhat related, but how much precision could I hope for
 *    from a libevent time?
 *
 * A: Actually, it's _very_ related if you're timing in order to have a
 * timeout happen.
 *
 * On Windows, it uses select: you could in theory have a microsecond
 * resolution, but it usually isn't that accurate.
 *
 * On OSX, iOS, and BSD, you have kqueue: You could in theory have a nanosecond
 * resolution, but it usually isn't that accurate.
 *
 * On Linux, you have epoll: It has a millisecond resolution.  Some recent
 * Libevents can also use timerfd for higher resolution if
 * EVENT_BASE_FLAG_PRECISE_TIMER is set: Tor doesn't set that flag.
 */

#ifndef TOR_COMPAT_TIME_H
#define TOR_COMPAT_TIME_H

#include "orconfig.h"
#include "lib/cc/torint.h"

#include "lib/wallclock/tor_gettimeofday.h"

#ifdef _WIN32
#undef HAVE_CLOCK_GETTIME
#endif

#if defined(HAVE_CLOCK_GETTIME)
/* to ensure definition of CLOCK_MONOTONIC_COARSE if it's there */
#include <time.h>
#endif

#if !defined(HAVE_STRUCT_TIMEVAL_TV_SEC)
/** Implementation of timeval for platforms that don't have it. */
struct timeval {
  time_t tv_sec;
  unsigned int tv_usec;
};
#endif /* !defined(HAVE_STRUCT_TIMEVAL_TV_SEC) */

/** Represents a monotonic timer in a platform-dependent way. */
typedef struct monotime_t {
#ifdef __APPLE__
  /* On apple, there is a 64-bit counter whose precision we must look up. */
  uint64_t abstime_;
#elif defined(HAVE_CLOCK_GETTIME)
  /* It sure would be nice to use clock_gettime(). Posix is a nice thing. */
  struct timespec ts_;
#elif defined (_WIN32)
  /* On Windows, there is a 64-bit counter whose precision we must look up. */
  int64_t pcount_;
#else
#define MONOTIME_USING_GETTIMEOFDAY
  /* Otherwise, we will be stuck using gettimeofday. */
  struct timeval tv_;
#endif /* defined(__APPLE__) || ... */
} monotime_t;

#if defined(CLOCK_MONOTONIC_COARSE) && \
  defined(HAVE_CLOCK_GETTIME)
#define MONOTIME_COARSE_FN_IS_DIFFERENT
#define monotime_coarse_t monotime_t
#elif defined(_WIN32)
#define MONOTIME_COARSE_FN_IS_DIFFERENT
#define MONOTIME_COARSE_TYPE_IS_DIFFERENT
/** Represents a coarse monotonic time in a platform-independent way. */
typedef struct monotime_coarse_t {
  uint64_t tick_count_;
} monotime_coarse_t;
#elif defined(__APPLE__) && defined(HAVE_MACH_APPROXIMATE_TIME)
#define MONOTIME_COARSE_FN_IS_DIFFERENT
#define monotime_coarse_t monotime_t
#else
#define monotime_coarse_t monotime_t
#endif /* defined(CLOCK_MONOTONIC_COARSE) && ... || ... */

/**
 * Initialize the timing subsystem. This function is idempotent.
 */
void monotime_init(void);
/**
 * Set <b>out</b> to the current time.
 */
void monotime_get(monotime_t *out);
/**
 * Return the number of nanoseconds between <b>start</b> and <b>end</b>.
 * The returned value may be equal to zero.
 */
int64_t monotime_diff_nsec(const monotime_t *start, const monotime_t *end);
/**
 * Return the number of microseconds between <b>start</b> and <b>end</b>.
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
int64_t monotime_diff_usec(const monotime_t *start, const monotime_t *end);
/**
 * Return the number of milliseconds between <b>start</b> and <b>end</b>.
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
int64_t monotime_diff_msec(const monotime_t *start, const monotime_t *end);
/**
 * Return the number of nanoseconds since the timer system was initialized.
 * The returned value may be equal to zero.
 */
uint64_t monotime_absolute_nsec(void);
/**
 * Return the number of microseconds since the timer system was initialized.
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
MOCK_DECL(uint64_t, monotime_absolute_usec,(void));
/**
 * Return the number of milliseconds since the timer system was initialized.
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
uint64_t monotime_absolute_msec(void);
/**
 * Return the number of seconds since the timer system was initialized.
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
uint64_t monotime_absolute_sec(void);
/**
 * Set <b>out</b> to zero.
 */
void monotime_zero(monotime_t *out);
/**
 * Return true iff <b>out</b> is zero
 */
int monotime_is_zero(const monotime_t *out);

/**
 * Set <b>out</b> to N milliseconds after <b>val</b>.
 */
/* XXXX We should add a more generic function here if we ever need to */
void monotime_add_msec(monotime_t *out, const monotime_t *val, uint32_t msec);

#if defined(MONOTIME_COARSE_FN_IS_DIFFERENT)
/**
 * Set <b>out</b> to the current coarse time.
 */
void monotime_coarse_get(monotime_coarse_t *out);
/**
 * Like monotime_absolute_*(), but faster on some platforms.
 */
uint64_t monotime_coarse_absolute_nsec(void);
uint64_t monotime_coarse_absolute_usec(void);
uint64_t monotime_coarse_absolute_msec(void);
uint64_t monotime_coarse_absolute_sec(void);
#else /* !defined(MONOTIME_COARSE_FN_IS_DIFFERENT) */
#define monotime_coarse_get monotime_get
#define monotime_coarse_absolute_nsec monotime_absolute_nsec
#define monotime_coarse_absolute_usec monotime_absolute_usec
#define monotime_coarse_absolute_msec monotime_absolute_msec
#define monotime_coarse_absolute_sec monotime_absolute_sec
#endif /* defined(MONOTIME_COARSE_FN_IS_DIFFERENT) */

/**
 * Return a "timestamp" approximation for a coarse monotonic timer.
 * This timestamp is meant to be fast to calculate and easy to
 * compare, and have a unit of something roughly around 1 msec.
 *
 * It will wrap over from time to time.
 *
 * It has no defined zero point.
 */
uint32_t monotime_coarse_to_stamp(const monotime_coarse_t *t);
/**
 * Convert a difference, expressed in the units of monotime_coarse_to_stamp,
 * into an approximate number of milliseconds.
 *
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
uint64_t monotime_coarse_stamp_units_to_approx_msec(uint64_t units);
uint64_t monotime_msec_to_approx_coarse_stamp_units(uint64_t msec);
uint32_t monotime_coarse_get_stamp(void);

#if defined(MONOTIME_COARSE_TYPE_IS_DIFFERENT)
/**
 * Like monotime_diff_*(), but faster on some platforms.
 */
int64_t monotime_coarse_diff_nsec(const monotime_coarse_t *start,
    const monotime_coarse_t *end);
int64_t monotime_coarse_diff_usec(const monotime_coarse_t *start,
    const monotime_coarse_t *end);
int64_t monotime_coarse_diff_msec(const monotime_coarse_t *start,
    const monotime_coarse_t *end);
/**
 * Like monotime_*(), but faster on some platforms.
 */
void monotime_coarse_zero(monotime_coarse_t *out);
int monotime_coarse_is_zero(const monotime_coarse_t *val);
void monotime_coarse_add_msec(monotime_coarse_t *out,
                              const monotime_coarse_t *val, uint32_t msec);
#else /* !defined(MONOTIME_COARSE_TYPE_IS_DIFFERENT) */
#define monotime_coarse_diff_nsec monotime_diff_nsec
#define monotime_coarse_diff_usec monotime_diff_usec
#define monotime_coarse_diff_msec monotime_diff_msec
#define monotime_coarse_zero monotime_zero
#define monotime_coarse_is_zero monotime_is_zero
#define monotime_coarse_add_msec monotime_add_msec
#endif /* defined(MONOTIME_COARSE_TYPE_IS_DIFFERENT) */

/**
 * As monotime_coarse_diff_msec, but avoid 64-bit division.
 *
 * Requires that the difference fit into an int32_t; not for use with
 * large time differences.
 *
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
int32_t monotime_coarse_diff_msec32_(const monotime_coarse_t *start,
                                     const monotime_coarse_t *end);

/**
 * As monotime_coarse_diff_msec, but avoid 64-bit division if it is expensive.
 *
 * Requires that the difference fit into an int32_t; not for use with
 * large time differences.
 *
 * The returned value may be equal to zero.
 * Fractional units are truncated, not rounded.
 */
static inline int32_t
monotime_coarse_diff_msec32(const monotime_coarse_t *start,
                            const monotime_coarse_t *end)
{
#if SIZEOF_VOID_P == 8
  // on a 64-bit platform, let's assume 64/64 division is cheap.
  return (int32_t) monotime_coarse_diff_msec(start, end);
#else
#define USING_32BIT_MSEC_HACK
  return monotime_coarse_diff_msec32_(start, end);
#endif /* SIZEOF_VOID_P == 8 */
}

#ifdef TOR_UNIT_TESTS
void tor_sleep_msec(int msec);

void monotime_enable_test_mocking(void);
void monotime_disable_test_mocking(void);
void monotime_set_mock_time_nsec(int64_t);
#if defined(MONOTIME_COARSE_FN_IS_DIFFERENT)
void monotime_coarse_set_mock_time_nsec(int64_t);
#else
#define monotime_coarse_set_mock_time_nsec monotime_set_mock_time_nsec
#endif
#endif /* defined(TOR_UNIT_TESTS) */

#ifdef COMPAT_TIME_PRIVATE
#if defined(_WIN32) || defined(TOR_UNIT_TESTS)
STATIC int64_t ratchet_performance_counter(int64_t count_raw);
STATIC int64_t ratchet_coarse_performance_counter(int64_t count_raw);
#endif
#if defined(MONOTIME_USING_GETTIMEOFDAY) || defined(TOR_UNIT_TESTS)
STATIC void ratchet_timeval(const struct timeval *timeval_raw,
                            struct timeval *out);
#endif
#ifdef TOR_UNIT_TESTS
void monotime_reset_ratchets_for_testing(void);
#endif
#endif /* defined(COMPAT_TIME_PRIVATE) */

#endif /* !defined(TOR_COMPAT_TIME_H) */
