/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file ns_detached_signatures_st.h
 * @brief Detached consensus signatures structure.
 **/

#ifndef NS_DETACHED_SIGNATURES_ST_H
#define NS_DETACHED_SIGNATURES_ST_H

/** A set of signatures for a networkstatus consensus.  Unless otherwise
 * noted, all fields are as for networkstatus_t. */
struct ns_detached_signatures_t {
  time_t valid_after;
  time_t fresh_until;
  time_t valid_until;
  strmap_t *digests; /**< Map from flavor name to digestset_t */
  strmap_t *signatures; /**< Map from flavor name to list of
                         * document_signature_t */
};

#endif /* !defined(NS_DETACHED_SIGNATURES_ST_H) */
