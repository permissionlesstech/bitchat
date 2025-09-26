/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file handles.h
 * \brief Macros for C weak-handle implementation.
 *
 * A 'handle' is a pointer to an object that is allowed to go away while
 * the handle stays alive.  When you dereference the handle, you might get
 * the object, or you might get "NULL".
 *
 * Use this pattern when an object has a single obvious lifespan, so you don't
 * want to use reference counting, but when other objects might need to refer
 * to the first object without caring about its lifetime.
 *
 * To enable a type to have handles, add a HANDLE_ENTRY() field in its
 * definition, as in:
 *
 *     struct walrus_t {
 *         HANDLE_ENTRY(wlr, walrus_t);
 *         // ...
 *     };
 *
 * And invoke HANDLE_DECL(wlr, walrus_t, [static]) to declare the handle
 * manipulation functions (typically in a header):
 *
 *     // opaque handle to walrus.
 *     typedef struct wlr_handle_t wlr_handle_t;
 *
 *     // make a new handle
 *     struct wlr_handle_t *wlr_handle_new(struct walrus_t *);
 *
 *     // release a handle
 *     void wlr_handle_free(wlr_handle_t *);
 *
 *     // return the pointed-to walrus, or NULL.
 *     struct walrus_t *wlr_handle_get(wlr_handle_t *).
 *
 *     // call this function when you're about to free the walrus;
 *     // it invalidates all handles. (IF YOU DON'T, YOU WILL HAVE
 *     // DANGLING REFERENCES)
 *     void wlr_handles_clear(struct walrus_t *);
 *
 * Finally, use HANDLE_IMPL() to define the above functions in some
 * appropriate C file: HANDLE_IMPL(wlr, walrus_t, [static])
 *
 **/

#ifndef TOR_HANDLE_H
#define TOR_HANDLE_H

#include "orconfig.h"

#include "lib/log/util_bug.h"
#include "lib/malloc/malloc.h"

#define HANDLE_ENTRY(name, structname)         \
  struct name ## _handle_head_t *handle_head

#define HANDLE_DECL(name, structname_t, linkage)                        \
  typedef struct name ## _handle_t name ## _handle_t;                   \
  linkage name ## _handle_t *name ## _handle_new(                       \
                                          struct structname_t *object); \
  linkage void name ## _handle_free_(name ## _handle_t *);              \
  linkage struct structname_t *name ## _handle_get(name ## _handle_t *); \
  linkage void name ## _handles_clear(struct structname_t *object);

/*
 * Implementation notes: there are lots of possible implementations here.  We
 * could keep a linked list of handles, each with a backpointer to the object,
 * and set all of their backpointers to NULL when the object is freed.  Or we
 * could have the clear function invalidate the object, but not actually let
 * the object get freed until the all the handles went away.  We could even
 * have a hash-table mapping unique identifiers to objects, and have each
 * handle be a copy of the unique identifier.  (We'll want to build that last
 * one eventually if we want cross-process handles.)
 *
 * But instead we're opting for a single independent 'head' that knows how
 * many handles there are, and where the object is (or isn't).  This makes
 * all of our functions O(1), and most as fast as a single pointer access.
 *
 * The handles themselves are opaque structures holding a pointer to the head.
 * We could instead have each foo_handle_t* be identical to foo_handle_head_t
 * *, and save some allocations ... but doing so would make handle leaks
 * harder to debug.  As it stands, every handle leak is a memory leak, and
 * existing memory debugging tools should help with those.  We can revisit
 * this decision if handles are too slow.
 */

#define HANDLE_IMPL(name, structname, linkage)                          \
  /* The 'head' object for a handle-accessible type. This object */     \
  /* persists for as long as the object, or any handles, exist. */      \
  typedef struct name ## _handle_head_t {                               \
    struct structname *object; /* pointed-to object, or NULL */         \
    unsigned int references; /* number of existing handles */           \
  } name ## _handle_head_t;                                             \
                                                                        \
  struct name ## _handle_t {                                            \
    struct name ## _handle_head_t *head; /* reference to the 'head'. */ \
  };                                                                    \
                                                                        \
  linkage struct name ## _handle_t *                                    \
  name ## _handle_new(struct structname *object)                        \
  {                                                                     \
    tor_assert(object);                                                 \
    name ## _handle_head_t *head = object->handle_head;                 \
    if (PREDICT_UNLIKELY(head == NULL)) {                               \
      head = object->handle_head = tor_malloc_zero(sizeof(*head));      \
      head->object = object;                                            \
    }                                                                   \
    name ## _handle_t *new_ref = tor_malloc_zero(sizeof(*new_ref));     \
    new_ref->head = head;                                               \
    ++head->references;                                                 \
    return new_ref;                                                     \
  }                                                                     \
                                                                        \
  linkage void                                                          \
  name ## _handle_free_(struct name ## _handle_t *ref)                   \
  {                                                                     \
    if (! ref) return;                                                  \
    name ## _handle_head_t *head = ref->head;                           \
    tor_assert(head);                                                   \
    --head->references;                                                 \
    tor_free(ref);                                                      \
    if (head->object == NULL && head->references == 0) {                \
      tor_free(head);                                                   \
      return;                                                           \
    }                                                                   \
  }                                                                     \
                                                                        \
  linkage struct structname *                                           \
  name ## _handle_get(struct name ## _handle_t *ref)                    \
  {                                                                     \
    tor_assert(ref);                                                    \
    name ## _handle_head_t *head = ref->head;                           \
    tor_assert(head);                                                   \
    return head->object;                                                \
  }                                                                     \
                                                                        \
  linkage void                                                          \
  name ## _handles_clear(struct structname *object)                     \
  {                                                                     \
    tor_assert(object);                                                 \
    name ## _handle_head_t *head = object->handle_head;                 \
    if (! head)                                                         \
      return;                                                           \
    object->handle_head = NULL;                                         \
    head->object = NULL;                                                \
    if (head->references == 0) {                                        \
      tor_free(head);                                                   \
    }                                                                   \
  }

#endif /* !defined(TOR_HANDLE_H) */
