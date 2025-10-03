/* Copyright (c) 2018 The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file ctassert.h
 *
 * \brief Compile-time assertions: CTASSERT(expression).
 */

#ifndef TOR_CTASSERT_H
#define TOR_CTASSERT_H

#include "lib/cc/compat_compiler.h"

/**
 * CTASSERT(expression)
 *
 *       Trigger a compiler error if expression is false.
 */
#if __STDC_VERSION__ >= 201112L

/* If C11 is available, just use _Static_assert.  */
#define CTASSERT(x) _Static_assert((x), #x)

#else /* !(__STDC_VERSION__ >= 201112L) */

/*
 * If C11 is not available, expand __COUNTER__, or __INCLUDE_LEVEL__
 * and __LINE__, or just __LINE__, with an intermediate preprocessor
 * macro CTASSERT_EXPN, and then use CTASSERT_DECL to paste the
 * expansions together into a unique name.
 *
 * We use this name as a typedef of an array type with a positive
 * length if the assertion is true, and a negative length of the
 * assertion is false, which is invalid and hence triggers a compiler
 * error.
 */
#if defined(__COUNTER__)
#define CTASSERT(x) CTASSERT_EXPN((x), c, __COUNTER__)
#elif defined(__INCLUDE_LEVEL__)
#define CTASSERT(x) CTASSERT_EXPN((x), __INCLUDE_LEVEL__, __LINE__)
#else
/* hope it's unique enough */
#define CTASSERT(x) CTASSERT_EXPN((x), l, __LINE__)
#endif /* defined(__COUNTER__) || ... */

#define CTASSERT_EXPN(x, a, b) CTASSERT_DECL(x, a, b)
#define CTASSERT_DECL(x, a, b) \
  typedef char tor_ctassert_##a##_##b[(x) ? 1 : -1] ATTR_UNUSED; EAT_SEMICOLON

#endif /* __STDC_VERSION__ >= 201112L */

#endif /* !defined(TOR_CTASSERT_H) */
