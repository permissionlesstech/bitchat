/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_MAP_H
#define TOR_MAP_H

/**
 * \file map.h
 *
 * \brief Headers for map.c.
 **/

#include "lib/testsupport/testsupport.h"
#include "lib/cc/torint.h"

#include "ext/siphash.h"

#define DECLARE_MAP_FNS(mapname_t, keytype, prefix)                     \
  typedef struct mapname_t mapname_t;                                   \
  typedef struct prefix##_entry_t *prefix##_iter_t;                       \
  MOCK_DECL(mapname_t*, prefix##_new, (void));                           \
  void* prefix##_set(mapname_t *map, keytype key, void *val);            \
  void* prefix##_get(const mapname_t *map, keytype key);                 \
  void* prefix##_remove(mapname_t *map, keytype key);                    \
  MOCK_DECL(void, prefix##_free_, (mapname_t *map, void (*free_val)(void*))); \
  int prefix##_isempty(const mapname_t *map);                            \
  int prefix##_size(const mapname_t *map);                               \
  prefix##_iter_t *prefix##_iter_init(mapname_t *map);                    \
  prefix##_iter_t *prefix##_iter_next(mapname_t *map, prefix##_iter_t *iter); \
  prefix##_iter_t *prefix##_iter_next_rmv(mapname_t *map,                 \
                                        prefix##_iter_t *iter);          \
  void prefix##_iter_get(prefix##_iter_t *iter, keytype *keyp, void **valp); \
  int prefix##_iter_done(prefix##_iter_t *iter);                          \
  void prefix##_assert_ok(const mapname_t *map)

/* Map from const char * to void *. Implemented with a hash table. */
DECLARE_MAP_FNS(strmap_t, const char *, strmap);
/* Map from const char[DIGEST_LEN] to void *. Implemented with a hash table. */
DECLARE_MAP_FNS(digestmap_t, const char *, digestmap);
/* Map from const uint8_t[DIGEST256_LEN] to void *. Implemented with a hash
 * table. */
DECLARE_MAP_FNS(digest256map_t, const uint8_t *, digest256map);

#define MAP_FREE_AND_NULL(mapname_t, map, fn)     \
  do {                                          \
    mapname_t ## _free_((map), (fn));             \
    (map) = NULL;                               \
  } while (0)

#define strmap_free(map, fn) MAP_FREE_AND_NULL(strmap, (map), (fn))
#define digestmap_free(map, fn) MAP_FREE_AND_NULL(digestmap, (map), (fn))
#define digest256map_free(map, fn) MAP_FREE_AND_NULL(digest256map, (map), (fn))

#undef DECLARE_MAP_FNS

/** Iterates over the key-value pairs in a map <b>map</b> in order.
 * <b>prefix</b> is as for DECLARE_MAP_FNS (i.e., strmap or digestmap).
 * The map's keys and values are of type keytype and valtype respectively;
 * each iteration assigns them to keyvar and valvar.
 *
 * Example use:
 *   MAP_FOREACH(digestmap, m, const char *, k, routerinfo_t *, r) {
 *     // use k and r
 *   } MAP_FOREACH_END.
 */
/* Unpacks to, approximately:
 * {
 *   digestmap_iter_t *k_iter;
 *   for (k_iter = digestmap_iter_init(m); !digestmap_iter_done(k_iter);
 *        k_iter = digestmap_iter_next(m, k_iter)) {
 *     const char *k;
 *     void *r_voidp;
 *     routerinfo_t *r;
 *     digestmap_iter_get(k_iter, &k, &r_voidp);
 *     r = r_voidp;
 *     // use k and r
 *   }
 * }
 */
#define MAP_FOREACH(prefix, map, keytype, keyvar, valtype, valvar)      \
  STMT_BEGIN                                                            \
    prefix##_iter_t *keyvar##_iter;                                      \
    for (keyvar##_iter = prefix##_iter_init(map);                        \
         !prefix##_iter_done(keyvar##_iter);                             \
         keyvar##_iter = prefix##_iter_next(map, keyvar##_iter)) {       \
      keytype keyvar;                                                   \
      void *valvar##_voidp;                                             \
      valtype valvar;                                                   \
      prefix##_iter_get(keyvar##_iter, &keyvar, &valvar##_voidp);        \
      valvar = valvar##_voidp;

/** As MAP_FOREACH, except allows members to be removed from the map
 * during the iteration via MAP_DEL_CURRENT.  Example use:
 *
 * Example use:
 *   MAP_FOREACH(digestmap, m, const char *, k, routerinfo_t *, r) {
 *      if (is_very_old(r))
 *       MAP_DEL_CURRENT(k);
 *   } MAP_FOREACH_END.
 **/
/* Unpacks to, approximately:
 * {
 *   digestmap_iter_t *k_iter;
 *   int k_del=0;
 *   for (k_iter = digestmap_iter_init(m); !digestmap_iter_done(k_iter);
 *        k_iter = k_del ? digestmap_iter_next(m, k_iter)
 *                       : digestmap_iter_next_rmv(m, k_iter)) {
 *     const char *k;
 *     void *r_voidp;
 *     routerinfo_t *r;
 *     k_del=0;
 *     digestmap_iter_get(k_iter, &k, &r_voidp);
 *     r = r_voidp;
 *     if (is_very_old(r)) {
 *       k_del = 1;
 *     }
 *   }
 * }
 */
#define MAP_FOREACH_MODIFY(prefix, map, keytype, keyvar, valtype, valvar) \
  STMT_BEGIN                                                            \
    prefix##_iter_t *keyvar##_iter;                                      \
    int keyvar##_del=0;                                                 \
    for (keyvar##_iter = prefix##_iter_init(map);                        \
         !prefix##_iter_done(keyvar##_iter);                             \
         keyvar##_iter = keyvar##_del ?                                 \
           prefix##_iter_next_rmv(map, keyvar##_iter) :                  \
           prefix##_iter_next(map, keyvar##_iter)) {                     \
      keytype keyvar;                                                   \
      void *valvar##_voidp;                                             \
      valtype valvar;                                                   \
      keyvar##_del=0;                                                   \
      prefix##_iter_get(keyvar##_iter, &keyvar, &valvar##_voidp);        \
      valvar = valvar##_voidp;

/** Used with MAP_FOREACH_MODIFY to remove the currently-iterated-upon
 * member of the map.  */
#define MAP_DEL_CURRENT(keyvar)                   \
  STMT_BEGIN                                      \
    keyvar##_del = 1;                             \
  STMT_END

/** Used to end a MAP_FOREACH() block. */
#define MAP_FOREACH_END } STMT_END ;

/** As MAP_FOREACH, but does not require declaration of prefix or keytype.
 * Example use:
 *   DIGESTMAP_FOREACH(m, k, routerinfo_t *, r) {
 *     // use k and r
 *   } DIGESTMAP_FOREACH_END.
 */
#define DIGESTMAP_FOREACH(map, keyvar, valtype, valvar)                 \
  MAP_FOREACH(digestmap, map, const char *, keyvar, valtype, valvar)

/** As MAP_FOREACH_MODIFY, but does not require declaration of prefix or
 * keytype.
 * Example use:
 *   DIGESTMAP_FOREACH_MODIFY(m, k, routerinfo_t *, r) {
 *      if (is_very_old(r))
 *       MAP_DEL_CURRENT(k);
 *   } DIGESTMAP_FOREACH_END.
 */
#define DIGESTMAP_FOREACH_MODIFY(map, keyvar, valtype, valvar)          \
  MAP_FOREACH_MODIFY(digestmap, map, const char *, keyvar, valtype, valvar)
/** Used to end a DIGESTMAP_FOREACH() block. */
#define DIGESTMAP_FOREACH_END MAP_FOREACH_END

#define DIGEST256MAP_FOREACH(map, keyvar, valtype, valvar)               \
  MAP_FOREACH(digest256map, map, const uint8_t *, keyvar, valtype, valvar)
#define DIGEST256MAP_FOREACH_MODIFY(map, keyvar, valtype, valvar)       \
  MAP_FOREACH_MODIFY(digest256map, map, const uint8_t *,               \
                     keyvar, valtype, valvar)
#define DIGEST256MAP_FOREACH_END MAP_FOREACH_END

#define STRMAP_FOREACH(map, keyvar, valtype, valvar)                 \
  MAP_FOREACH(strmap, map, const char *, keyvar, valtype, valvar)
#define STRMAP_FOREACH_MODIFY(map, keyvar, valtype, valvar)          \
  MAP_FOREACH_MODIFY(strmap, map, const char *, keyvar, valtype, valvar)
#define STRMAP_FOREACH_END MAP_FOREACH_END

void* strmap_set_lc(strmap_t *map, const char *key, void *val);
void* strmap_get_lc(const strmap_t *map, const char *key);
void* strmap_remove_lc(strmap_t *map, const char *key);

#define DECLARE_TYPED_DIGESTMAP_FNS(prefix, mapname_t, valtype)           \
  typedef struct mapname_t mapname_t;                                   \
  typedef struct prefix##_iter_t *prefix##_iter_t;                        \
  ATTR_UNUSED static inline mapname_t*                                  \
  prefix##_new(void)                                                     \
  {                                                                     \
    return (mapname_t*)digestmap_new();                                 \
  }                                                                     \
  ATTR_UNUSED static inline digestmap_t*                                \
  prefix##_to_digestmap(mapname_t *map)                                  \
  {                                                                     \
    return (digestmap_t*)map;                                           \
  }                                                                     \
  ATTR_UNUSED static inline valtype*                                    \
  prefix##_get(mapname_t *map, const char *key)                          \
  {                                                                     \
    return (valtype*)digestmap_get((digestmap_t*)map, key);             \
  }                                                                     \
  ATTR_UNUSED static inline valtype*                                    \
  prefix##_set(mapname_t *map, const char *key, valtype *val)            \
  {                                                                     \
    return (valtype*)digestmap_set((digestmap_t*)map, key, val);        \
  }                                                                     \
  ATTR_UNUSED static inline valtype*                                    \
  prefix##_remove(mapname_t *map, const char *key)                       \
  {                                                                     \
    return (valtype*)digestmap_remove((digestmap_t*)map, key);          \
  }                                                                     \
  ATTR_UNUSED static inline void                                        \
  prefix##_f##ree_(mapname_t *map, void (*free_val)(void*))              \
  {                                                                     \
    digestmap_free_((digestmap_t*)map, free_val);                       \
  }                                                                     \
  ATTR_UNUSED static inline int                                         \
  prefix##_isempty(mapname_t *map)                                       \
  {                                                                     \
    return digestmap_isempty((digestmap_t*)map);                        \
  }                                                                     \
  ATTR_UNUSED static inline int                                         \
  prefix##_size(mapname_t *map)                                          \
  {                                                                     \
    return digestmap_size((digestmap_t*)map);                           \
  }                                                                     \
  ATTR_UNUSED static inline                                             \
  prefix##_iter_t *prefix##_iter_init(mapname_t *map)                     \
  {                                                                     \
    return (prefix##_iter_t*) digestmap_iter_init((digestmap_t*)map);    \
  }                                                                     \
  ATTR_UNUSED static inline                                             \
  prefix##_iter_t *prefix##_iter_next(mapname_t *map, prefix##_iter_t *iter) \
  {                                                                     \
    return (prefix##_iter_t*) digestmap_iter_next(                       \
                       (digestmap_t*)map, (digestmap_iter_t*)iter);     \
  }                                                                     \
  ATTR_UNUSED static inline prefix##_iter_t*                             \
  prefix##_iter_next_rmv(mapname_t *map, prefix##_iter_t *iter)           \
  {                                                                     \
    return (prefix##_iter_t*) digestmap_iter_next_rmv(                   \
                       (digestmap_t*)map, (digestmap_iter_t*)iter);     \
  }                                                                     \
  ATTR_UNUSED static inline void                                        \
  prefix##_iter_get(prefix##_iter_t *iter,                                \
                   const char **keyp,                                   \
                   valtype **valp)                                      \
  {                                                                     \
    void *v;                                                            \
    digestmap_iter_get((digestmap_iter_t*) iter, keyp, &v);             \
    *valp = v;                                                          \
  }                                                                     \
  ATTR_UNUSED static inline int                                         \
  prefix##_iter_done(prefix##_iter_t *iter)                               \
  {                                                                     \
    return digestmap_iter_done((digestmap_iter_t*)iter);                \
  }

#endif /* !defined(TOR_MAP_H) */
