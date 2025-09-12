/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file time_fmt.h
 *
 * \brief Header for time_fmt.c
 **/

#ifndef TOR_TIME_FMT_H
#define TOR_TIME_FMT_H

#include "orconfig.h"
#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif

#include "lib/testsupport/testsupport.h"

struct tm;
struct timeval;

struct tm *tor_localtime_r(const time_t *timep, struct tm *result);
struct tm *tor_gmtime_r(const time_t *timep, struct tm *result);
int tor_timegm(const struct tm *tm, time_t *time_out);

#define RFC1123_TIME_LEN 29
void format_rfc1123_time(char *buf, time_t t);
int parse_rfc1123_time(const char *buf, time_t *t);
#define ISO_TIME_LEN 19
#define ISO_TIME_USEC_LEN (ISO_TIME_LEN+7)
void format_local_iso_time(char *buf, time_t t);
void format_iso_time(char *buf, time_t t);
void format_local_iso_time_nospace(char *buf, time_t t);
void format_iso_time_nospace(char *buf, time_t t);
void format_iso_time_nospace_usec(char *buf, const struct timeval *tv);
int parse_iso_time_(const char *cp, time_t *t, int strict, int nospace);
int parse_iso_time(const char *buf, time_t *t);
int parse_iso_time_nospace(const char *cp, time_t *t);
int parse_http_time(const char *buf, struct tm *tm);
int format_time_interval(char *out, size_t out_len, long interval);

#ifdef TIME_FMT_PRIVATE
STATIC int tor_timegm_impl(const struct tm *tm, time_t *time_out);
#endif

#endif /* !defined(TOR_TIME_FMT_H) */
