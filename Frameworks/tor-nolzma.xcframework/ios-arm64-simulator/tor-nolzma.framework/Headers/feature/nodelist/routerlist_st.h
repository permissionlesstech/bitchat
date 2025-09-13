/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file routerlist_st.h
 * @brief Router descriptor list structure.
 **/

#ifndef ROUTERLIST_ST_H
#define ROUTERLIST_ST_H

#include "feature/nodelist/desc_store_st.h"

/** Contents of a directory of onion routers. */
struct routerlist_t {
  /** Map from server identity digest to a member of routers. */
  struct digest_ri_map_t *identity_map;
  /** Map from server descriptor digest to a signed_descriptor_t from
   * routers or old_routers. */
  struct digest_sd_map_t *desc_digest_map;
  /** Map from extra-info digest to an extrainfo_t.  Only exists for
   * routers in routers or old_routers. */
  struct digest_ei_map_t *extra_info_map;
  /** Map from extra-info digests to a signed_descriptor_t for a router
   * descriptor having that extra-info digest.  Only exists for
   * routers in routers or old_routers. */
  struct digest_sd_map_t *desc_by_eid_map;
  /** List of routerinfo_t for all currently live routers we know. */
  smartlist_t *routers;
  /** List of signed_descriptor_t for older router descriptors we're
   * caching. */
  smartlist_t *old_routers;
  /** Store holding server descriptors.  If present, any router whose
   * cache_info.saved_location == SAVED_IN_CACHE is stored in this file
   * starting at cache_info.saved_offset */
  desc_store_t desc_store;
  /** Store holding extra-info documents. */
  desc_store_t extrainfo_store;
};

#endif /* !defined(ROUTERLIST_ST_H) */
