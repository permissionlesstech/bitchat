/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_SMARTLIST_H
#define TOR_SMARTLIST_H

/**
 * \file smartlist.h
 *
 * \brief Header for smartlist.c
 **/

#include <stdarg.h>
#include <stddef.h>

#include "lib/smartlist_core/smartlist_core.h"
#include "lib/smartlist_core/smartlist_foreach.h"
#include "lib/smartlist_core/smartlist_split.h"

void smartlist_add_asprintf(struct smartlist_t *sl, const char *pattern, ...)
  CHECK_PRINTF(2, 3);
void smartlist_add_vasprintf(struct smartlist_t *sl, const char *pattern,
                             va_list args)
  CHECK_PRINTF(2, 0);
void smartlist_reverse(smartlist_t *sl);
void smartlist_string_remove(smartlist_t *sl, const char *element);
int smartlist_contains_string(const smartlist_t *sl, const char *element);
int smartlist_pos(const smartlist_t *sl, const void *element);
int smartlist_string_pos(const smartlist_t *, const char *elt);
int smartlist_contains_string_case(const smartlist_t *sl, const char *element);
int smartlist_contains_int_as_string(const smartlist_t *sl, int num);
int smartlist_strings_eq(const smartlist_t *sl1, const smartlist_t *sl2);
int smartlist_contains_digest(const smartlist_t *sl, const char *element);
int smartlist_ints_eq(const smartlist_t *sl1, const smartlist_t *sl2);
int smartlist_overlap(const smartlist_t *sl1, const smartlist_t *sl2);
void smartlist_intersect(smartlist_t *sl1, const smartlist_t *sl2);
void smartlist_subtract(smartlist_t *sl1, const smartlist_t *sl2);

int smartlist_ptrs_eq(const smartlist_t *s1,
                      const smartlist_t *s2);

void smartlist_sort(smartlist_t *sl,
                    int (*compare)(const void **a, const void **b));
void *smartlist_get_most_frequent_(const smartlist_t *sl,
                    int (*compare)(const void **a, const void **b),
                    int *count_out);
#define smartlist_get_most_frequent(sl, compare) \
  smartlist_get_most_frequent_((sl), (compare), NULL)
void smartlist_uniq(smartlist_t *sl,
                    int (*compare)(const void **a, const void **b),
                    void (*free_fn)(void *elt));

void smartlist_sort_strings(smartlist_t *sl);
void smartlist_sort_digests(smartlist_t *sl);
void smartlist_sort_digests256(smartlist_t *sl);
void smartlist_sort_pointers(smartlist_t *sl);

const char *smartlist_get_most_frequent_string(smartlist_t *sl);
const char *smartlist_get_most_frequent_string_(smartlist_t *sl,
                                                int *count_out);
const uint8_t *smartlist_get_most_frequent_digest256(smartlist_t *sl);

void smartlist_uniq_strings(smartlist_t *sl);
void smartlist_uniq_digests(smartlist_t *sl);
void smartlist_uniq_digests256(smartlist_t *sl);
void *smartlist_bsearch(const smartlist_t *sl, const void *key,
                        int (*compare)(const void *key, const void **member));
int smartlist_bsearch_idx(const smartlist_t *sl, const void *key,
                          int (*compare)(const void *key, const void **member),
                          int *found_out);

void smartlist_pqueue_add(smartlist_t *sl,
                          int (*compare)(const void *a, const void *b),
                          ptrdiff_t idx_field_offset,
                          void *item);
void *smartlist_pqueue_pop(smartlist_t *sl,
                           int (*compare)(const void *a, const void *b),
                           ptrdiff_t idx_field_offset);
void smartlist_pqueue_remove(smartlist_t *sl,
                             int (*compare)(const void *a, const void *b),
                             ptrdiff_t idx_field_offset,
                             void *item);
void smartlist_pqueue_assert_ok(smartlist_t *sl,
                                int (*compare)(const void *a, const void *b),
                                ptrdiff_t idx_field_offset);

char *smartlist_join_strings(smartlist_t *sl, const char *join, int terminate,
                             size_t *len_out) ATTR_MALLOC;
char *smartlist_join_strings2(smartlist_t *sl, const char *join,
                              size_t join_len, int terminate, size_t *len_out)
  ATTR_MALLOC;

#ifndef COCCI
/* Helper: Given two lists of items, possibly of different types, such that
 * both lists are sorted on some common field (as determined by a comparison
 * expression <b>cmpexpr</b>), and such that one list (<b>sl1</b>) has no
 * duplicates on the common field, loop through the lists in lockstep, and
 * execute <b>unmatched_var2</b> on items in var2 that do not appear in
 * var1.
 *
 * WARNING: It isn't safe to add remove elements from either list while the
 * loop is in progress.
 *
 * Example use:
 *  SMARTLIST_FOREACH_JOIN(routerstatus_list, routerstatus_t *, rs,
 *                     routerinfo_list, routerinfo_t *, ri,
 *                    tor_memcmp(rs->identity_digest, ri->identity_digest, 20),
 *                     log_info(LD_GENERAL,"No match for %s", ri->nickname)) {
 *    log_info(LD_GENERAL, "%s matches routerstatus %p", ri->nickname, rs);
 * } SMARTLIST_FOREACH_JOIN_END(rs, ri);
 **/
/* The example above unpacks (approximately) to:
 *  int rs_sl_idx = 0, rs_sl_len = smartlist_len(routerstatus_list);
 *  int ri_sl_idx, ri_sl_len = smartlist_len(routerinfo_list);
 *  int rs_ri_cmp;
 *  routerstatus_t *rs;
 *  routerinfo_t *ri;
 *  for (; ri_sl_idx < ri_sl_len; ++ri_sl_idx) {
 *    ri = smartlist_get(routerinfo_list, ri_sl_idx);
 *    while (rs_sl_idx < rs_sl_len) {
 *      rs = smartlist_get(routerstatus_list, rs_sl_idx);
 *      rs_ri_cmp = tor_memcmp(rs->identity_digest, ri->identity_digest, 20);
 *      if (rs_ri_cmp > 0) {
 *        break;
 *      } else if (rs_ri_cmp == 0) {
 *        goto matched_ri;
 *      } else {
 *        ++rs_sl_idx;
 *      }
 *    }
 *    log_info(LD_GENERAL,"No match for %s", ri->nickname);
 *    continue;
 *   matched_ri: {
 *    log_info(LD_GENERAL,"%s matches with routerstatus %p",ri->nickname,rs);
 *    }
 *  }
 */
#define SMARTLIST_FOREACH_JOIN(sl1, type1, var1, sl2, type2, var2,      \
                                cmpexpr, unmatched_var2)                \
  STMT_BEGIN                                                            \
  int var1 ## _sl_idx = 0, var1 ## _sl_len=(sl1)->num_used;             \
  int var2 ## _sl_idx = 0, var2 ## _sl_len=(sl2)->num_used;             \
  int var1 ## _ ## var2 ## _cmp;                                        \
  type1 var1;                                                           \
  type2 var2;                                                           \
  for (; var2##_sl_idx < var2##_sl_len; ++var2##_sl_idx) {              \
    var2 = (sl2)->list[var2##_sl_idx];                                  \
    while (var1##_sl_idx < var1##_sl_len) {                             \
      var1 = (sl1)->list[var1##_sl_idx];                                \
      var1##_##var2##_cmp = (cmpexpr);                                  \
      if (var1##_##var2##_cmp > 0) {                                    \
        break;                                                          \
      } else if (var1##_##var2##_cmp == 0) {                            \
        goto matched_##var2;                                            \
      } else {                                                          \
        ++var1##_sl_idx;                                                \
      }                                                                 \
    }                                                                   \
    /* Ran out of v1, or no match for var2. */                          \
    unmatched_var2;                                                     \
    continue;                                                           \
    matched_##var2: ;                                                   \

#define SMARTLIST_FOREACH_JOIN_END(var1, var2)  \
  }                                             \
  STMT_END
#endif /* !defined(COCCI) */

#endif /* !defined(TOR_SMARTLIST_H) */
