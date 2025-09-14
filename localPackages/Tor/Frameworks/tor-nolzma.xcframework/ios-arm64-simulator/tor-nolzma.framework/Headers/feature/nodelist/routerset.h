/* Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file routerset.h
 * \brief Header file for routerset.c
 **/

#ifndef TOR_ROUTERSET_H
#define TOR_ROUTERSET_H

routerset_t *routerset_new(void);
void routerset_refresh_countries(routerset_t *rs);
int routerset_parse(routerset_t *target, const char *s,
                    const char *description);
void routerset_union(routerset_t *target, const routerset_t *source);
int routerset_is_list(const routerset_t *set);
int routerset_needs_geoip(const routerset_t *set);
int routerset_is_empty(const routerset_t *set);
int routerset_contains_router(const routerset_t *set, const routerinfo_t *ri,
                              country_t country);
int routerset_contains_routerstatus(const routerset_t *set,
                                    const routerstatus_t *rs,
                                    country_t country);
int routerset_contains_extendinfo(const routerset_t *set,
                                  const extend_info_t *ei);
struct bridge_info_t;
int routerset_contains_bridge(const routerset_t *set,
                              const struct bridge_info_t *bridge);
int routerset_contains_node(const routerset_t *set, const node_t *node);

void routerset_get_all_nodes(smartlist_t *out, const routerset_t *routerset,
                             const routerset_t *excludeset,
                             int running_only);
int routerset_add_unknown_ccs(routerset_t **setp, int only_if_some_cc_set);
void routerset_subtract_nodes(smartlist_t *out,
                                const routerset_t *routerset);

char *routerset_to_string(const routerset_t *routerset);
int routerset_equal(const routerset_t *old, const routerset_t *new);
void routerset_free_(routerset_t *routerset);
#define routerset_free(rs) FREE_AND_NULL(routerset_t, routerset_free_, (rs))
int routerset_len(const routerset_t *set);

struct var_type_def_t;
extern const struct var_type_def_t ROUTERSET_type_defn;
typedef routerset_t *config_decl_ROUTERSET;

#ifdef ROUTERSET_PRIVATE
#include "lib/container/bitarray.h"

STATIC char * routerset_get_countryname(const char *c);
STATIC int routerset_contains(const routerset_t *set, const tor_addr_t *addr,
                   uint16_t orport,
                   const char *nickname, const char *id_digest,
                   country_t country);

/** A routerset specifies constraints on a set of possible routerinfos, based
 * on their names, identities, or addresses.  It is optimized for determining
 * whether a router is a member or not, in O(1+P) time, where P is the number
 * of address policy constraints. */
struct routerset_t {
  /** A list of strings for the elements of the policy.  Each string is either
   * a nickname, a hexadecimal identity fingerprint, or an address policy.  A
   * router belongs to the set if its nickname OR its identity OR its address
   * matches an entry here. */
  smartlist_t *list;
  /** A map from lowercase nicknames of routers in the set to (void*)1 */
  strmap_t *names;
  /** A map from identity digests routers in the set to (void*)1 */
  digestmap_t *digests;
  /** An address policy for routers in the set.  For implementation reasons,
   * a router belongs to the set if it is _rejected_ by this policy. */
  smartlist_t *policies;

  /** A human-readable description of what this routerset is for.  Used in
   * log messages. */
  char *description;

  /** A list of the country codes in this set. */
  smartlist_t *country_names;
  /** Total number of countries we knew about when we built <b>countries</b>.*/
  int n_countries;
  /** Bit array mapping the return value of geoip_get_country() to 1 iff the
   * country is a member of this routerset.  Note that we MUST call
   * routerset_refresh_countries() whenever the geoip country list is
   * reloaded. */
  bitarray_t *countries;
  /** If true, subsequent assignments to this routerset should replace
   * it, not extend it.  Set only on the first item in a routerset in an
   * or_options_t. */
  unsigned int fragile:1;
};
#endif /* defined(ROUTERSET_PRIVATE) */
#endif /* !defined(TOR_ROUTERSET_H) */
