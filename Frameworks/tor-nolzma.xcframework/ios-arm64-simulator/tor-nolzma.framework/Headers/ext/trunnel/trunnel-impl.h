/* trunnel-impl.h -- copied from Trunnel v1.5.3
 * https://gitweb.torproject.org/trunnel.git
 * You probably shouldn't edit this file.
 */
/* trunnel-impl.h -- Implementation helpers for trunnel, included by
 * generated trunnel files
 *
 * Copyright 2014-2019, The Tor Project, Inc.
 * See license at the end of this file for copying information.
 */

#ifndef TRUNNEL_IMPL_H_INCLUDED_
#define TRUNNEL_IMPL_H_INCLUDED_
#ifdef TRUNNEL_LOCAL_H
#include "trunnel-local.h"
#endif
#include "trunnel.h"
#include <assert.h>
#include <string.h>
#include <stdlib.h>

#if defined(_MSC_VER) && (_MSC_VER < 1600)
#define uint8_t unsigned char
#define uint16_t unsigned short
#define uint32_t unsigned int
#define uint64_t unsigned __int64
#define inline __inline
#else
#include <stdint.h>
#endif

#ifdef _WIN32
uint32_t trunnel_htonl(uint32_t a);
uint32_t trunnel_ntohl(uint32_t a);
uint16_t trunnel_htons(uint16_t a);
uint16_t trunnel_ntohs(uint16_t a);
#else
#include <arpa/inet.h>
#define trunnel_htonl(x) htonl(x)
#define trunnel_htons(x) htons(x)
#define trunnel_ntohl(x) ntohl(x)
#define trunnel_ntohs(x) ntohs(x)
#endif
uint64_t trunnel_htonll(uint64_t a);
uint64_t trunnel_ntohll(uint64_t a);

#ifndef trunnel_assert
#define trunnel_assert(x) assert(x)
#endif

static inline void
trunnel_set_uint64(void *p, uint64_t v) {
  memcpy(p, &v, 8);
}
static inline void
trunnel_set_uint32(void *p, uint32_t v) {
  memcpy(p, &v, 4);
}
static inline void
trunnel_set_uint16(void *p, uint16_t v) {
  memcpy(p, &v, 2);
}
static inline void
trunnel_set_uint8(void *p, uint8_t v) {
  memcpy(p, &v, 1);
}

static inline uint64_t
trunnel_get_uint64(const void *p) {
  uint64_t x;
  memcpy(&x, p, 8);
  return x;
}
static inline uint32_t
trunnel_get_uint32(const void *p) {
  uint32_t x;
  memcpy(&x, p, 4);
  return x;
}
static inline uint16_t
trunnel_get_uint16(const void *p) {
  uint16_t x;
  memcpy(&x, p, 2);
  return x;
}
static inline uint8_t
trunnel_get_uint8(const void *p) {
  return *(const uint8_t*)p;
}


#ifdef TRUNNEL_DEBUG_FAILING_ALLOC
extern int trunnel_provoke_alloc_failure;

static inline void *
trunnel_malloc(size_t n)
{
   if (trunnel_provoke_alloc_failure) {
     if (--trunnel_provoke_alloc_failure == 0)
       return NULL;
   }
   return malloc(n);
}
static inline void *
trunnel_calloc(size_t a, size_t b)
{
   if (trunnel_provoke_alloc_failure) {
     if (--trunnel_provoke_alloc_failure == 0)
       return NULL;
   }
   return calloc(a,b);
}
static inline char *
trunnel_strdup(const char *s)
{
   if (trunnel_provoke_alloc_failure) {
     if (--trunnel_provoke_alloc_failure == 0)
       return NULL;
   }
   return strdup(s);
}
#else
#ifndef trunnel_malloc
#define trunnel_malloc(x) (malloc((x)))
#endif
#ifndef trunnel_calloc
#define trunnel_calloc(a,b) (calloc((a),(b)))
#endif
#ifndef trunnel_strdup
#define trunnel_strdup(s) (strdup((s)))
#endif
#endif

#ifndef trunnel_realloc
#define trunnel_realloc(a,b) realloc((a),(b))
#endif

#ifndef trunnel_free_
#define trunnel_free_(x) (free(x))
#endif
#define trunnel_free(x) ((x) ? (trunnel_free_(x),0) : (0))

#ifndef trunnel_abort
#define trunnel_abort() abort()
#endif

#ifndef trunnel_memwipe
#define trunnel_memwipe(mem, len) ((void)0)
#define trunnel_wipestr(s) ((void)0)
#else
#define trunnel_wipestr(s) do {                 \
    if (s)                                      \
      trunnel_memwipe(s, strlen(s));            \
  } while (0)
#endif

/* ====== dynamic arrays ======== */

#ifdef NDEBUG
#define TRUNNEL_DYNARRAY_GET(da, n)             \
  ((da)->elts_[(n)])
#else
/** Return the 'n'th element of 'da'. */
#define TRUNNEL_DYNARRAY_GET(da, n)             \
  (((n) >= (da)->n_ ? (trunnel_abort(),0) : 0), (da)->elts_[(n)])
#endif

/** Change the 'n'th element of 'da' to 'v'. */
#define TRUNNEL_DYNARRAY_SET(da, n, v) do {                    \
    trunnel_assert((n) < (da)->n_);                            \
    (da)->elts_[(n)] = (v);                                    \
  } while (0)

/** Expand the dynamic array 'da' of 'elttype' so that it can hold at least
 * 'howmanymore' elements than its current capacity. Always tries to increase
 * the length of the array. On failure, run the code in 'on_fail' and goto
 * trunnel_alloc_failed. */
#define TRUNNEL_DYNARRAY_EXPAND(elttype, da, howmanymore, on_fail) do { \
    elttype *newarray;                                               \
    newarray = trunnel_dynarray_expand(&(da)->allocated_,            \
                                       (da)->elts_, (howmanymore),   \
                                       sizeof(elttype));             \
    if (newarray == NULL) {                                          \
      on_fail;                                                       \
      goto trunnel_alloc_failed;                                     \
    }                                                                \
    (da)->elts_ = newarray;                                          \
  } while (0)

/** Add 'v' to the end of the dynamic array 'da' of 'elttype', expanding it if
 * necessary.  code in 'on_fail' and goto trunnel_alloc_failed. */
#define TRUNNEL_DYNARRAY_ADD(elttype, da, v, on_fail) do { \
      if ((da)->n_ == (da)->allocated_) {                  \
        TRUNNEL_DYNARRAY_EXPAND(elttype, da, 1, on_fail);  \
      }                                                    \
      (da)->elts_[(da)->n_++] = (v);                       \
    } while (0)

/** Return the number of elements in 'da'. */
#define TRUNNEL_DYNARRAY_LEN(da) ((da)->n_)

/** Remove all storage held by 'da' and set it to be empty.  Does not free
 * storage held by the elements themselves. */
#define TRUNNEL_DYNARRAY_CLEAR(da) do {           \
    trunnel_free((da)->elts_);                    \
    (da)->elts_ = NULL;                           \
    (da)->n_ = (da)->allocated_ = 0;              \
  } while (0)

/** Remove all storage held by 'da' and set it to be empty.  Does not free
 * storage held by the elements themselves. */
#define TRUNNEL_DYNARRAY_WIPE(da) do {                                  \
    trunnel_memwipe((da)->elts_, (da)->allocated_ * sizeof((da)->elts_[0])); \
  } while (0)

/** Helper: wraps or implements an OpenBSD-style reallocarray.  Behaves
 * as realloc(a, x*y), but verifies that no overflow will occur in the
 * multiplication. Returns NULL on failure. */
#ifndef trunnel_reallocarray
void *trunnel_reallocarray(void *a, size_t x, size_t y);
#endif

/** Helper to expand a dynamic array. Behaves as TRUNNEL_DYNARRAY_EXPAND(),
 * taking the array of elements in 'ptr', a pointer to thethe current number
 * of allocated elements in allocated_p, the minimum numbeer of elements to
 * add in 'howmanymore', and the size of a single element in 'eltsize'.
 *
 * On success, adjust *allocated_p, and return the new value for the array of
 * elements.  On failure, adjust nothing and return NULL.
 */
void *trunnel_dynarray_expand(size_t *allocated_p, void *ptr,
                              size_t howmanymore, size_t eltsize);

/** Type for a function to free members of a dynarray of pointers. */
typedef void (*trunnel_free_fn_t)(void *);

/**
 * Helper to change the length of a dynamic array. Takes pointers to the
 * current allocated and n fields of the array in 'allocated_p' and 'len_p',
 * and the current array of elements in 'ptr'; takes the length of a single
 * element in 'eltsize'.  Changes the length to 'newlen'.  If 'newlen' is
 * greater than the current length, pads the new elements with 0.  If newlen
 * is less than the current length, and free_fn is non-NULL, treat the
 * array as an array of void *, and invoke free_fn() on each removed element.
 *
 * On success, adjust *allocated_p and *len_p, and return the new value for
 * the array of elements.  On failure, adjust nothing, set *errcode_ptr to 1,
 * and return NULL.
 */
void *trunnel_dynarray_setlen(size_t *allocated_p, size_t *len_p,
                              void *ptr, size_t newlen,
                              size_t eltsize, trunnel_free_fn_t free_fn,
                              uint8_t *errcode_ptr);

/**
 * Helper: return a pointer to the value of 'str' as a NUL-terminated string.
 * Might have to reallocate the storage for 'str' in order to fit in the final
 * NUL character.  On allocation failure, return NULL.
 */
const char *trunnel_string_getstr(trunnel_string_t *str);

/**
 * Helper: change the contents of 'str' to hold the 'len'-byte string in
 * 'inp'.  Adjusts the storage to have a terminating NUL that doesn't count
 * towards the length of the string.  On success, return 0.  On failure, set
 * *errcode_ptr to 1 and return -1.
 */
int trunnel_string_setstr0(trunnel_string_t *str, const char *inp, size_t len,
                           uint8_t *errcode_ptr);

/**
 * As trunnel_dynarray_setlen, but adjusts a string rather than a dynamic
 * array, and ensures that the new string is NUL-terminated.
 */
int trunnel_string_setlen(trunnel_string_t *str, size_t newlen,
                           uint8_t *errcode_ptr);

#endif


/*
Copyright 2014  The Tor Project, Inc.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

    * Neither the names of the copyright owners nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
