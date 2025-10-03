/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file cmp.h
 *
 * \brief Macro definitions for MIN, MAX, and CLAMP.
 **/

#ifndef TOR_INTMATH_CMP_H
#define TOR_INTMATH_CMP_H

/** Macros for MIN/MAX.  Never use these when the arguments could have
 * side-effects.
 * {With GCC extensions we could probably define a safer MIN/MAX.  But
 * depending on that safety would be dangerous, since not every platform
 * has it.}
 **/
#ifndef MAX
#define MAX(a,b) ( ((a)<(b)) ? (b) : (a) )
#endif
#ifndef MIN
#define MIN(a,b) ( ((a)>(b)) ? (b) : (a) )
#endif

/* Return <b>v</b> if it's between <b>min</b> and <b>max</b>.  Otherwise
 * return <b>min</b> if <b>v</b> is smaller than <b>min</b>, or <b>max</b> if
 * <b>b</b> is larger than <b>max</b>.
 *
 * Requires that <b>min</b> is no more than <b>max</b>. May evaluate any of
 * its arguments more than once! */
#define CLAMP(min,v,max)                        \
  ( ((v) < (min)) ? (min) :                     \
    ((v) > (max)) ? (max) :                     \
    (v) )

/** Give the absolute value of <b>x</b>, independent of its type. */
#define ABS(x) ( ((x)<0) ? -(x) : (x) )

#endif /* !defined(TOR_INTMATH_CMP_H) */
