/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file smartlist_core.h
 * \brief Top-level declarations for the smartlist_t dynamic array type.
 **/

#ifndef TOR_SMARTLIST_CORE_H
#define TOR_SMARTLIST_CORE_H

#include <stddef.h>

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"

/** A resizeable list of pointers, with associated helpful functionality.
 *
 * The members of this struct are exposed only so that macros and inlines can
 * use them; all access to smartlist internals should go through the functions
 * and macros defined here.
 **/
typedef struct smartlist_t {
  /** @{ */
  /** <b>list</b> has enough capacity to store exactly <b>capacity</b> elements
   * before it needs to be resized.  Only the first <b>num_used</b> (\<=
   * capacity) elements point to valid data.
   */
  void **list;
  int num_used;
  int capacity;
  /** @} */
} smartlist_t;

MOCK_DECL(smartlist_t *, smartlist_new, (void));
MOCK_DECL(void, smartlist_free_, (smartlist_t *sl));
#define smartlist_free(sl) FREE_AND_NULL(smartlist_t, smartlist_free_, (sl))

void smartlist_clear(smartlist_t *sl);
void smartlist_add(smartlist_t *sl, void *element);
void smartlist_add_all(smartlist_t *sl, const smartlist_t *s2);
void smartlist_add_strdup(struct smartlist_t *sl, const char *string);
void smartlist_grow(smartlist_t *sl, size_t new_size);

void smartlist_remove(smartlist_t *sl, const void *element);
void smartlist_remove_keeporder(smartlist_t *sl, const void *element);
void *smartlist_pop_last(smartlist_t *sl);

int smartlist_contains(const smartlist_t *sl, const void *element);

/* smartlist_choose() is defined in crypto.[ch] */
#ifdef DEBUG_SMARTLIST
#include "lib/err/torerr.h"
#include <stdlib.h>
/** Return the number of items in sl.
 */
static inline int smartlist_len(const smartlist_t *sl);
static inline int smartlist_len(const smartlist_t *sl) {
  raw_assert(sl);
  return (sl)->num_used;
}
/** Return the <b>idx</b>th element of sl.
 */
static inline void *smartlist_get(const smartlist_t *sl, int idx);
static inline void *smartlist_get(const smartlist_t *sl, int idx) {
  raw_assert(sl);
  raw_assert(idx>=0);
  raw_assert(sl->num_used > idx);
  return sl->list[idx];
}
static inline void smartlist_set(smartlist_t *sl, int idx, void *val) {
  raw_assert(sl);
  raw_assert(idx>=0);
  raw_assert(sl->num_used > idx);
  sl->list[idx] = val;
}
#else /* !defined(DEBUG_SMARTLIST) */
#define smartlist_len(sl) ((sl)->num_used)
#define smartlist_get(sl, idx) ((sl)->list[idx])
#define smartlist_set(sl, idx, val) ((sl)->list[idx] = (val))
#endif /* defined(DEBUG_SMARTLIST) */

/** Exchange the elements at indices <b>idx1</b> and <b>idx2</b> of the
 * smartlist <b>sl</b>. */
static inline void smartlist_swap(smartlist_t *sl, int idx1, int idx2)
{
  if (idx1 != idx2) {
    void *elt = smartlist_get(sl, idx1);
    smartlist_set(sl, idx1, smartlist_get(sl, idx2));
    smartlist_set(sl, idx2, elt);
  }
}

void smartlist_del(smartlist_t *sl, int idx);
void smartlist_del_keeporder(smartlist_t *sl, int idx);
void smartlist_insert(smartlist_t *sl, int idx, void *val);

#endif /* !defined(TOR_SMARTLIST_CORE_H) */
