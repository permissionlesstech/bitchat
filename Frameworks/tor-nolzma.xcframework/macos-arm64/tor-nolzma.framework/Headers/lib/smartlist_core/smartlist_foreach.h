/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file smartlist_foreach.h
 * \brief Macros for iterating over the elements of a smartlist_t.
 **/

#ifndef TOR_SMARTLIST_FOREACH_H
#define TOR_SMARTLIST_FOREACH_H

/** Iterate over the items in a smartlist <b>sl</b>, in order.  For each item,
 * assign it to a new local variable of type <b>type</b> named <b>var</b>, and
 * execute the statements inside the loop body.  Inside the loop, the loop
 * index can be accessed as <b>var</b>_sl_idx and the length of the list can
 * be accessed as <b>var</b>_sl_len.
 *
 * NOTE: Do not change the length of the list while the loop is in progress,
 * unless you adjust the _sl_len variable correspondingly.  See second example
 * below.
 *
 * Example use:
 * <pre>
 *   smartlist_t *list = smartlist_split("A:B:C", ":", 0, 0);
 *   SMARTLIST_FOREACH_BEGIN(list, char *, cp) {
 *     printf("%d: %s\n", cp_sl_idx, cp);
 *     tor_free(cp);
 *   } SMARTLIST_FOREACH_END(cp);
 *   smartlist_free(list);
 * </pre>
 *
 * Example use (advanced):
 * <pre>
 *   SMARTLIST_FOREACH_BEGIN(list, char *, cp) {
 *     if (!strcmp(cp, "junk")) {
 *       tor_free(cp);
 *       SMARTLIST_DEL_CURRENT(list, cp);
 *     }
 *   } SMARTLIST_FOREACH_END(cp);
 * </pre>
 */
/* Note: these macros use token pasting, and reach into smartlist internals.
 * This can make them a little daunting. Here's the approximate unpacking of
 * the above examples, for entertainment value:
 *
 * <pre>
 * smartlist_t *list = smartlist_split("A:B:C", ":", 0, 0);
 * {
 *   int cp_sl_idx, cp_sl_len = smartlist_len(list);
 *   char *cp;
 *   for (cp_sl_idx = 0; cp_sl_idx < cp_sl_len; ++cp_sl_idx) {
 *     cp = smartlist_get(list, cp_sl_idx);
 *     printf("%d: %s\n", cp_sl_idx, cp);
 *     tor_free(cp);
 *   }
 * }
 * smartlist_free(list);
 * </pre>
 *
 * <pre>
 * {
 *   int cp_sl_idx, cp_sl_len = smartlist_len(list);
 *   char *cp;
 *   for (cp_sl_idx = 0; cp_sl_idx < cp_sl_len; ++cp_sl_idx) {
 *     cp = smartlist_get(list, cp_sl_idx);
 *     if (!strcmp(cp, "junk")) {
 *       tor_free(cp);
 *       smartlist_del(list, cp_sl_idx);
 *       --cp_sl_idx;
 *       --cp_sl_len;
 *     }
 *   }
 * }
 * </pre>
 */
#define SMARTLIST_FOREACH_BEGIN(sl, type, var)  \
  STMT_BEGIN                                                    \
    int var ## _sl_idx, var ## _sl_len=(sl)->num_used;          \
    type var;                                                   \
    for (var ## _sl_idx = 0; var ## _sl_idx < var ## _sl_len;   \
         ++var ## _sl_idx) {                                    \
      var = (sl)->list[var ## _sl_idx];

/** Iterates over the items in smartlist <b>sl</b> in reverse order, similar to
 *  SMARTLIST_FOREACH_BEGIN
 *
 * NOTE: This macro is incompatible with SMARTLIST_DEL_CURRENT.
 */
#define SMARTLIST_FOREACH_REVERSE_BEGIN(sl, type, var)  \
  STMT_BEGIN                                                       \
    int var ## _sl_idx, var ## _sl_len=(sl)->num_used;             \
    type var;                                                      \
    for (var ## _sl_idx = var ## _sl_len-1; var ## _sl_idx >= 0;   \
         --var ## _sl_idx) {                                       \
      var = (sl)->list[var ## _sl_idx];

#define SMARTLIST_FOREACH_END(var)              \
    var = NULL;                                 \
    (void) var ## _sl_idx;                      \
  } STMT_END

/**
 * An alias for SMARTLIST_FOREACH_BEGIN and SMARTLIST_FOREACH_END, using
 * <b>cmd</b> as the loop body.  This wrapper is here for convenience with
 * very short loops.
 *
 * By convention, we do not use this for loops which nest, or for loops over
 * 10 lines or so.  Use SMARTLIST_FOREACH_{BEGIN,END} for those.
 */
#define SMARTLIST_FOREACH(sl, type, var, cmd)                   \
  SMARTLIST_FOREACH_BEGIN(sl,type,var) {                        \
    cmd;                                                        \
  } SMARTLIST_FOREACH_END(var)

/** Helper: While in a SMARTLIST_FOREACH loop over the list <b>sl</b> indexed
 * with the variable <b>var</b>, remove the current element in a way that
 * won't confuse the loop. */
#define SMARTLIST_DEL_CURRENT(sl, var)          \
  STMT_BEGIN                                    \
    smartlist_del(sl, var ## _sl_idx);          \
    --var ## _sl_idx;                           \
    --var ## _sl_len;                           \
  STMT_END

/** Helper: While in a SMARTLIST_FOREACH loop over the list <b>sl</b> indexed
 * with the variable <b>var</b>, remove the current element in a way that
 * won't confuse the loop. */
#define SMARTLIST_DEL_CURRENT_KEEPORDER(sl, var)          \
  STMT_BEGIN                                              \
     smartlist_del_keeporder(sl, var ## _sl_idx);         \
     --var ## _sl_idx;                                    \
     --var ## _sl_len;                                    \
  STMT_END

/** Helper: While in a SMARTLIST_FOREACH loop over the list <b>sl</b> indexed
 * with the variable <b>var</b>, replace the current element with <b>val</b>.
 * Does not deallocate the current value of <b>var</b>.
 */
#define SMARTLIST_REPLACE_CURRENT(sl, var, val) \
  STMT_BEGIN                                    \
    smartlist_set(sl, var ## _sl_idx, val);     \
  STMT_END

#endif /* !defined(TOR_SMARTLIST_FOREACH_H) */
