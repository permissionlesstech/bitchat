/* Copyright (c) 2008-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file memarea.h
 *
 * \brief Header for memarea.c
 **/

#ifndef TOR_MEMAREA_H
#define TOR_MEMAREA_H

#include <stddef.h>

typedef struct memarea_t memarea_t;

memarea_t *memarea_new(void);
void memarea_drop_all_(memarea_t *area);
/** @copydoc memarea_drop_all_
 *
 * Additionally, set <b>area</b> to NULL. */
#define memarea_drop_all(area) \
  do {                                          \
    memarea_drop_all_(area);                    \
    (area) = NULL;                              \
  } while (0)
void memarea_clear(memarea_t *area);
int memarea_owns_ptr(const memarea_t *area, const void *ptr);
void *memarea_alloc(memarea_t *area, size_t sz);
void *memarea_alloc_zero(memarea_t *area, size_t sz);
void *memarea_memdup(memarea_t *area, const void *s, size_t n);
char *memarea_strdup(memarea_t *area, const char *s);
char *memarea_strndup(memarea_t *area, const char *s, size_t n);
void memarea_get_stats(memarea_t *area,
                       size_t *allocated_out, size_t *used_out);
void memarea_assert_ok(memarea_t *area);

#endif /* !defined(TOR_MEMAREA_H) */
