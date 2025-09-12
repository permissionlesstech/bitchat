/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file torint.h
 *
 * \brief Integer definitions used throughout Tor.
 **/

#ifndef TOR_TORINT_H
#define TOR_TORINT_H

#include "orconfig.h"

#include <stdint.h>
#include <stdbool.h>
#include <limits.h>

#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif
#ifdef HAVE_SYS_LIMITS_H
#include <sys/limits.h>
#endif

#ifndef SIZE_MAX
#if SIZEOF_SIZE_T == 8
#define SIZE_MAX UINT64_MAX
#elif  SIZEOF_SIZE_T == 4
#define SIZE_MAX UINT32_MAX
#else
#error "Can't define SIZE_MAX"
#endif /* SIZEOF_SIZE_T == 8 || ... */
#endif /* !defined(SIZE_MAX) */

#ifndef HAVE_SSIZE_T
#if SIZEOF_SIZE_T == 8
typedef int64_t ssize_t;
#elif SIZEOF_SIZE_T == 4
typedef int32_t ssize_t;
#else
#error "Can't define ssize_t."
#endif /* SIZEOF_SIZE_T == 8 || ... */
#endif /* !defined(HAVE_SSIZE_T) */

/* This assumes a sane (2's-complement) representation.  But if you
 * aren't 2's complement, and you don't define LONG_MAX, then you're so
 * bizarre that I want nothing to do with you. */
#ifndef USING_TWOS_COMPLEMENT
#error "Your platform doesn't use 2's complement arithmetic."
#endif

#ifndef TIME_MAX

#if (SIZEOF_TIME_T == SIZEOF_INT)
#define TIME_MAX ((time_t)INT_MAX)
#elif (SIZEOF_TIME_T == SIZEOF_LONG)
#define TIME_MAX ((time_t)LONG_MAX)
#elif (SIZEOF_TIME_T == 8)
#define TIME_MAX ((time_t)INT64_MAX)
#else
#error "Can't define TIME_MAX"
#endif /* (SIZEOF_TIME_T == SIZEOF_INT) || ... */

#endif /* !defined(TIME_MAX) */

#ifndef TIME_MIN

#if (SIZEOF_TIME_T == SIZEOF_INT)
#define TIME_MIN ((time_t)INT_MIN)
#elif (SIZEOF_TIME_T == SIZEOF_LONG)
#define TIME_MIN ((time_t)LONG_MIN)
#elif (SIZEOF_TIME_T == 8)
#define TIME_MIN ((time_t)INT64_MIN)
#else
#error "Can't define TIME_MIN"
#endif /* (SIZEOF_TIME_T == SIZEOF_INT) || ... */

#endif /* !defined(TIME_MIN) */

#ifndef SIZE_MAX
#if (SIZEOF_SIZE_T == 4)
#define SIZE_MAX UINT32_MAX
#elif (SIZEOF_SIZE_T == 8)
#define SIZE_MAX UINT64_MAX
#else
#error "Can't define SIZE_MAX"
#endif /* (SIZEOF_SIZE_T == 4) || ... */
#endif /* !defined(SIZE_MAX) */

#ifdef _WIN32
#  ifdef _WIN64
#    define TOR_PRIuSZ PRIu64
#  else
#    define TOR_PRIuSZ PRIu32
#  endif
#else /* !defined(_WIN32) */
#  define TOR_PRIuSZ "zu"
#endif /* defined(_WIN32) */

#ifdef _WIN32
#  ifdef _WIN64
#    define TOR_PRIdSZ PRId64
#  else
#    define TOR_PRIdSZ PRId32
#  endif
#else /* !defined(_WIN32) */
#  define TOR_PRIdSZ "zd"
#endif /* defined(_WIN32) */

#ifndef SSIZE_MAX
#if (SIZEOF_SIZE_T == 4)
#define SSIZE_MAX INT32_MAX
#elif (SIZEOF_SIZE_T == 8)
#define SSIZE_MAX INT64_MAX
#else
#error "Can't define SSIZE_MAX"
#endif /* (SIZEOF_SIZE_T == 4) || ... */
#endif /* !defined(SSIZE_MAX) */

/** Any ssize_t larger than this amount is likely to be an underflow. */
#define SSIZE_T_CEILING ((ssize_t)(SSIZE_MAX-16))
/** Any size_t larger than this amount is likely to be an underflow. */
#define SIZE_T_CEILING  ((size_t)(SSIZE_MAX-16))

#if SIZEOF_INT > SIZEOF_VOID_P
#error "sizeof(int) > sizeof(void *) - Can't build Tor here."
#endif

#if SIZEOF_UNSIGNED_INT > SIZEOF_VOID_P
#error "sizeof(unsigned int) > sizeof(void *) - Can't build Tor here."
#endif

#endif /* !defined(TOR_TORINT_H) */
