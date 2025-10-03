/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dircollate.h
 * \brief Header file for dircollate.c.
 **/

#ifndef TOR_DIRCOLLATE_H
#define TOR_DIRCOLLATE_H

#include "lib/testsupport/testsupport.h"
#include "core/or/or.h"

typedef struct dircollator_t dircollator_t;

dircollator_t *dircollator_new(int n_votes, int n_authorities);
void dircollator_free_(dircollator_t *obj);
#define dircollator_free(c) \
  FREE_AND_NULL(dircollator_t, dircollator_free_, (c))
void dircollator_add_vote(dircollator_t *dc, networkstatus_t *v);

void dircollator_collate(dircollator_t *dc, int consensus_method);

int dircollator_n_routers(dircollator_t *dc);
vote_routerstatus_t **dircollator_get_votes_for_router(dircollator_t *dc,
                                                       int idx);

#ifdef DIRCOLLATE_PRIVATE
struct ddmap_entry_t;
typedef HT_HEAD(double_digest_map, ddmap_entry_t) double_digest_map_t;
/** A dircollator keeps track of all the routerstatus entries in a
 * set of networkstatus votes, and matches them by an appropriate rule. */
struct dircollator_t {
  /** True iff we have run the collation algorithm. */
  int is_collated;
  /** The total number of votes that we received. */
  int n_votes;
  /** The total number of authorities we acknowledge. */
  int n_authorities;

  /** The index which the next vote to be added to this collator should
   * receive. */
  int next_vote_num;
  /** Map from RSA-SHA1 identity digest to an array of <b>n_votes</b>
   * vote_routerstatus_t* pointers, such that the i'th member of the
   * array is the i'th vote's entry for that RSA-SHA1 ID.*/
  digestmap_t *by_rsa_sha1;
  /** Map from <ed, RSA-SHA1> pair to an array similar to that used in
   * by_rsa_sha1 above. We include <NULL,RSA-SHA1> entries for votes that
   * say that there is no Ed key. */
  struct double_digest_map by_both_ids;

  /** One of two outputs created by collation: a map from RSA-SHA1
   * identity digest to an array of the vote_routerstatus_t objects.  Entries
   * only exist in this map for identities that we should include in the
   * consensus. */
  digestmap_t *by_collated_rsa_sha1;

  /** One of two outputs created by collation: a sorted array of RSA-SHA1
   * identity digests .*/
  smartlist_t *all_rsa_sha1_lst;
};
#endif /* defined(DIRCOLLATE_PRIVATE) */

#endif /* !defined(TOR_DIRCOLLATE_H) */

