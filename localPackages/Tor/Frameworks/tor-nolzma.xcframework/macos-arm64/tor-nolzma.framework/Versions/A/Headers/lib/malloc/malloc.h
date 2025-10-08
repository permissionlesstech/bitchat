/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file malloc.h
 * \brief Headers for util_malloc.c
 **/

#ifndef TOR_UTIL_MALLOC_H
#define TOR_UTIL_MALLOC_H

#include <assert.h>
#include <stddef.h>
#include <stdlib.h>
#include "lib/cc/compat_compiler.h"

/* Memory management */
void *tor_malloc_(size_t size) ATTR_MALLOC;
void *tor_malloc_zero_(size_t size) ATTR_MALLOC;
void *tor_calloc_(size_t nmemb, size_t size) ATTR_MALLOC;
void *tor_realloc_(void *ptr, size_t size);
void *tor_reallocarray_(void *ptr, size_t size1, size_t size2);
char *tor_strdup_(const char *s) ATTR_MALLOC;
char *tor_strndup_(const char *s, size_t n)
  ATTR_MALLOC;
void *tor_memdup_(const void *mem, size_t len)
  ATTR_MALLOC;
void *tor_memdup_nulterm_(const void *mem, size_t len)
  ATTR_MALLOC;
void tor_free_(void *mem);

/** Release memory allocated by tor_malloc, tor_realloc, tor_strdup,
 * etc.  Unlike the free() function, the tor_free() macro sets the
 * pointer value to NULL after freeing it.
 *
 * This is a macro.  If you need a function pointer to release memory from
 * tor_malloc(), use tor_free_().
 *
 * Note that this macro takes the address of the pointer it is going to
 * free and clear.  If that pointer is stored with a nonstandard
 * alignment (eg because of a "packed" pragma) it is not correct to use
 * tor_free().
 */
#ifdef __GNUC__
#define tor_free(p) STMT_BEGIN                                 \
    typeof(&(p)) tor_free__tmpvar = &(p);                      \
    _Static_assert(!__builtin_types_compatible_p(typeof(*tor_free__tmpvar), \
                                                 struct event *), \
                   "use tor_event_free for struct event *");   \
    raw_free(*tor_free__tmpvar);                               \
    *tor_free__tmpvar=NULL;                                    \
  STMT_END
#else /* !defined(__GNUC__) */
#define tor_free(p) STMT_BEGIN                                 \
  raw_free(p);                                                 \
  (p)=NULL;                                                    \
  STMT_END
#endif /* defined(__GNUC__) */

#define tor_malloc(size)       tor_malloc_(size)
#define tor_malloc_zero(size)  tor_malloc_zero_(size)
#define tor_calloc(nmemb,size) tor_calloc_(nmemb, size)
#define tor_realloc(ptr, size) tor_realloc_(ptr, size)
#define tor_reallocarray(ptr, sz1, sz2) \
  tor_reallocarray_((ptr), (sz1), (sz2))
#define tor_strdup(s)          tor_strdup_(s)
#define tor_strndup(s, n)      tor_strndup_(s, n)
#define tor_memdup(s, n)       tor_memdup_(s, n)
#define tor_memdup_nulterm(s, n)       tor_memdup_nulterm_(s, n)

/* Aliases for the underlying system malloc/realloc/free. Only use
 * them to indicate "I really want the underlying system function, I know
 * what I'm doing." */
#define raw_malloc  malloc
#define raw_realloc realloc
#define raw_free    free
#define raw_strdup  strdup

/* Helper macro: free a variable of type 'typename' using freefn, and
 * set the variable to NULL.
 */
#define FREE_AND_NULL(typename, freefn, var)                            \
  do {                                                                  \
    /* only evaluate (var) once. */                                     \
    typename **tmp__free__ptr ## freefn = &(var);                       \
    freefn(*tmp__free__ptr ## freefn);                                  \
    (*tmp__free__ptr ## freefn) = NULL;                                 \
  } while (0)

#ifdef UTIL_MALLOC_PRIVATE
STATIC int size_mul_check(const size_t x, const size_t y);
#endif

#endif /* !defined(TOR_UTIL_MALLOC_H) */
