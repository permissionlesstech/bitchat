/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_ORDER_H
#define TOR_ORDER_H

/**
 * \file order.h
 *
 * \brief Header for order.c.
 **/

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"

/* These functions, given an <b>array</b> of <b>n_elements</b>, return the
 * <b>nth</b> lowest element. <b>nth</b>=0 gives the lowest element;
 * <b>n_elements</b>-1 gives the highest; and (<b>n_elements</b>-1) / 2 gives
 * the median.  As a side effect, the elements of <b>array</b> are sorted. */
int find_nth_int(int *array, int n_elements, int nth);
time_t find_nth_time(time_t *array, int n_elements, int nth);
double find_nth_double(double *array, int n_elements, int nth);
int32_t find_nth_int32(int32_t *array, int n_elements, int nth);
uint32_t find_nth_uint32(uint32_t *array, int n_elements, int nth);
long find_nth_long(long *array, int n_elements, int nth);
static inline int
median_int(int *array, int n_elements)
{
  return find_nth_int(array, n_elements, (n_elements-1)/2);
}
static inline time_t
median_time(time_t *array, int n_elements)
{
  return find_nth_time(array, n_elements, (n_elements-1)/2);
}
static inline double
median_double(double *array, int n_elements)
{
  return find_nth_double(array, n_elements, (n_elements-1)/2);
}
static inline uint32_t
median_uint32(uint32_t *array, int n_elements)
{
  return find_nth_uint32(array, n_elements, (n_elements-1)/2);
}
static inline int32_t
median_int32(int32_t *array, int n_elements)
{
  return find_nth_int32(array, n_elements, (n_elements-1)/2);
}

static inline uint32_t
third_quartile_uint32(uint32_t *array, int n_elements)
{
  return find_nth_uint32(array, n_elements, (n_elements*3)/4);
}

#endif /* !defined(TOR_ORDER_H) */
