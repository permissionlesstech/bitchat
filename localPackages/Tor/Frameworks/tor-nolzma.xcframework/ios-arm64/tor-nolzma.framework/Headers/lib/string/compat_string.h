/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compat_string.h
 * \brief Header for compat_string.c
 **/

#ifndef TOR_COMPAT_STRING_H
#define TOR_COMPAT_STRING_H

#include "orconfig.h"
#include "lib/cc/compat_compiler.h"

#include <stddef.h>

/* ===== String compatibility */
#ifdef _WIN32
/* Windows doesn't have str(n)casecmp, but mingw defines it: only define it
 * ourselves if it's missing. */
#ifndef HAVE_STRNCASECMP
static inline int strncasecmp(const char *a, const char *b, size_t n);
static inline int strncasecmp(const char *a, const char *b, size_t n) {
  return _strnicmp(a,b,n);
}
#endif /* !defined(HAVE_STRNCASECMP) */
#ifndef HAVE_STRCASECMP
static inline int strcasecmp(const char *a, const char *b);
static inline int strcasecmp(const char *a, const char *b) {
  return _stricmp(a,b);
}
#endif /* !defined(HAVE_STRCASECMP) */
#endif /* defined(_WIN32) */

#if defined __APPLE__
/* On OSX 10.9 and later, the overlap-checking code for strlcat would
 * appear to have a severe bug that can sometimes cause aborts in Tor.
 * Instead, use the non-checking variants.  This is sad.
 *
 * (If --enable-fragile-hardening is passed to configure, we use the hardened
 * variants, which do not suffer from this issue.)
 *
 * See https://bugs.torproject.org/tpo/core/tor/15205.
 */
#undef strlcat
#undef strlcpy
#endif /* defined __APPLE__ */

#ifndef HAVE_STRLCAT
size_t strlcat(char *dst, const char *src, size_t siz);
#endif
#ifndef HAVE_STRLCPY
size_t strlcpy(char *dst, const char *src, size_t siz);
#endif

char *tor_strtok_r_impl(char *str, const char *sep, char **lasts);
#ifdef HAVE_STRTOK_R
#define tor_strtok_r(str, sep, lasts) strtok_r(str, sep, lasts)
#else
#define tor_strtok_r(str, sep, lasts) tor_strtok_r_impl(str, sep, lasts)
#endif

#endif /* !defined(TOR_COMPAT_STRING_H) */
