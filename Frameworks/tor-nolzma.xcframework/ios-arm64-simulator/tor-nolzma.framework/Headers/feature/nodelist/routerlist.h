/* Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file routerlist.h
 * \brief Header file for routerlist.c.
 **/

#ifndef TOR_ROUTERLIST_H
#define TOR_ROUTERLIST_H

#include "lib/testsupport/testsupport.h"

/** Return value for router_add_to_routerlist() and dirserv_add_descriptor() */
typedef enum was_router_added_t {
  /* Router was added successfully. */
  ROUTER_ADDED_SUCCESSFULLY = 1,
  /* Extrainfo document was rejected because no corresponding router
   * descriptor was found OR router descriptor was rejected because
   * it was incompatible with its extrainfo document. */
  ROUTER_BAD_EI = -1,
  /* Router descriptor was rejected because it is already known. */
  ROUTER_IS_ALREADY_KNOWN = -2,
  /* General purpose router was rejected, because it was not listed
   * in consensus. */
  ROUTER_NOT_IN_CONSENSUS = -3,
  /* Router was neither in directory consensus nor in any of
   * networkstatus documents. Caching it to access later.
   * (Applies to fetched descriptors only.) */
  ROUTER_NOT_IN_CONSENSUS_OR_NETWORKSTATUS = -4,
  /* Router was rejected by directory authority. */
  ROUTER_AUTHDIR_REJECTS = -5,
  /* Bridge descriptor was rejected because such bridge was not one
   * of the bridges we have listed in our configuration. */
  ROUTER_WAS_NOT_WANTED = -6,
  /* Router descriptor was rejected because it was older than
   * OLD_ROUTER_DESC_MAX_AGE. */
  ROUTER_WAS_TOO_OLD = -7, /* note contrast with 'ROUTER_IS_ALREADY_KNOWN' */
  /* Some certs on this router are expired. */
  ROUTER_CERTS_EXPIRED = -8,
  /* We couldn't format the annotations for this router. This is a directory
   * authority bug. */
  ROUTER_AUTHDIR_BUG_ANNOTATIONS = -10
} was_router_added_t;

/** How long do we avoid using a directory server after it's given us a 503? */
#define DIR_503_TIMEOUT (60*60)

int router_reload_router_list(void);

int router_or_conn_should_skip_reachable_address_check(
                                       const or_options_t *options,
                                       int try_ip_pref);
int router_dir_conn_should_skip_reachable_address_check(
                                       const or_options_t *options,
                                       int try_ip_pref);
void router_reset_status_download_failures(void);
int routers_have_same_or_addrs(const routerinfo_t *r1, const routerinfo_t *r2);
bool router_can_choose_node(const node_t *node, int flags);
void router_add_running_nodes_to_smartlist(smartlist_t *sl, int flags);

const routerinfo_t *routerlist_find_my_routerinfo(void);
uint32_t router_get_advertised_bandwidth(const routerinfo_t *router);
uint32_t router_get_advertised_bandwidth_capped(const routerinfo_t *router);

int hexdigest_to_digest(const char *hexdigest, char *digest);
const routerinfo_t *router_get_by_id_digest(const char *digest);
routerinfo_t *router_get_mutable_by_digest(const char *digest);
signed_descriptor_t *router_get_by_descriptor_digest(const char *digest);
MOCK_DECL(signed_descriptor_t *,router_get_by_extrainfo_digest,
          (const char *digest));
MOCK_DECL(signed_descriptor_t *,extrainfo_get_by_descriptor_digest,
          (const char *digest));
const char *signed_descriptor_get_body(const signed_descriptor_t *desc);
const char *signed_descriptor_get_annotations(const signed_descriptor_t *desc);
routerlist_t *router_get_routerlist(void);
void routerinfo_free_(routerinfo_t *router);
#define routerinfo_free(router) \
  FREE_AND_NULL(routerinfo_t, routerinfo_free_, (router))
void extrainfo_free_(extrainfo_t *extrainfo);
#define extrainfo_free(ei) FREE_AND_NULL(extrainfo_t, extrainfo_free_, (ei))
void routerlist_free_(routerlist_t *rl);
#define routerlist_free(rl) FREE_AND_NULL(routerlist_t, routerlist_free_, (rl))
void dump_routerlist_mem_usage(int severity);
void routerlist_remove(routerlist_t *rl, routerinfo_t *ri, int make_old,
                       time_t now);
void routerlist_free_all(void);
void routerlist_reset_warnings(void);

/* XXXX move this */
void list_pending_downloads(digestmap_t *result,
                            digest256map_t *result256,
                            int purpose, const char *prefix);

static int WRA_WAS_ADDED(was_router_added_t s);
static int WRA_WAS_OUTDATED(was_router_added_t s);
static int WRA_WAS_REJECTED(was_router_added_t s);
static int WRA_NEVER_DOWNLOADABLE(was_router_added_t s);
/** Return true iff the outcome code in <b>s</b> indicates that the descriptor
 * was added. It might still be necessary to check whether the descriptor
 * generator should be notified.
 */
static inline int
WRA_WAS_ADDED(was_router_added_t s) {
  return s == ROUTER_ADDED_SUCCESSFULLY;
}
/** Return true iff the outcome code in <b>s</b> indicates that the descriptor
 * was not added because it was either:
 * - not in the consensus
 * - neither in the consensus nor in any networkstatus document
 * - it was outdated.
 * - its certificates were expired.
 */
static inline int WRA_WAS_OUTDATED(was_router_added_t s)
{
  return (s == ROUTER_WAS_TOO_OLD ||
          s == ROUTER_IS_ALREADY_KNOWN ||
          s == ROUTER_NOT_IN_CONSENSUS ||
          s == ROUTER_NOT_IN_CONSENSUS_OR_NETWORKSTATUS ||
          s == ROUTER_CERTS_EXPIRED);
}
/** Return true iff the outcome code in <b>s</b> indicates that the descriptor
 * was flat-out rejected. */
static inline int WRA_WAS_REJECTED(was_router_added_t s)
{
  return (s == ROUTER_AUTHDIR_REJECTS);
}
/** Return true iff the outcome code in <b>s</b> indicates that the descriptor
 * was flat-out rejected. */
static inline int WRA_NEVER_DOWNLOADABLE(was_router_added_t s)
{
  return (s == ROUTER_AUTHDIR_REJECTS ||
          s == ROUTER_BAD_EI ||
          s == ROUTER_WAS_TOO_OLD ||
          s == ROUTER_CERTS_EXPIRED);
}
was_router_added_t router_add_to_routerlist(routerinfo_t *router,
                                            const char **msg,
                                            int from_cache,
                                            int from_fetch);
was_router_added_t router_add_extrainfo_to_routerlist(
                                        extrainfo_t *ei, const char **msg,
                                        int from_cache, int from_fetch);
void routerlist_descriptors_added(smartlist_t *sl, int from_cache);
void routerlist_remove_old_routers(void);
void routerlist_drop_bridge_descriptors(void);
int router_load_single_router(const char *s, uint8_t purpose, int cache,
                              const char **msg);
int router_load_routers_from_string(const char *s, const char *eos,
                                     saved_location_t saved_location,
                                     smartlist_t *requested_fingerprints,
                                     int descriptor_digests,
                                     const char *prepend_annotations);
void router_load_extrainfo_from_string(const char *s, const char *eos,
                                       saved_location_t saved_location,
                                       smartlist_t *requested_fingerprints,
                                       int descriptor_digests);

void routerlist_retry_directory_downloads(time_t now);

int router_exit_policy_rejects_all(const routerinfo_t *router);

void update_consensus_router_descriptor_downloads(time_t now, int is_vote,
                                                  networkstatus_t *consensus);
void update_router_descriptor_downloads(time_t now);
void update_all_descriptor_downloads(time_t now);
void update_extrainfo_downloads(time_t now);
void router_reset_descriptor_download_failures(void);
int router_differences_are_cosmetic(const routerinfo_t *r1,
                                    const routerinfo_t *r2);
int routerinfo_incompatible_with_extrainfo(const crypto_pk_t *ri,
                                           extrainfo_t *ei,
                                           signed_descriptor_t *sd,
                                           const char **msg);
int routerinfo_has_curve25519_onion_key(const routerinfo_t *ri);
int routerstatus_version_supports_extend2_cells(const routerstatus_t *rs,
                                                int allow_unknown_versions);

void routerlist_assert_ok(const routerlist_t *rl);
const char *esc_router_info(const routerinfo_t *router);
void routers_sort_by_identity(smartlist_t *routers);

void refresh_all_country_info(void);

void list_pending_microdesc_downloads(digest256map_t *result);
void launch_descriptor_downloads(int purpose,
                                 smartlist_t *downloadable,
                                 const routerstatus_t *source,
                                 time_t now);

int hex_digest_nickname_decode(const char *hexdigest,
                               char *digest_out,
                               char *nickname_qualifier_out,
                               char *nickname_out);
int hex_digest_nickname_matches(const char *hexdigest,
                                const char *identity_digest,
                                const char *nickname);

#ifdef ROUTERLIST_PRIVATE
MOCK_DECL(int, router_descriptor_is_older_than, (const routerinfo_t *router,
                                                 int seconds));
MOCK_DECL(STATIC was_router_added_t, extrainfo_insert,
          (routerlist_t *rl, extrainfo_t *ei, int warn_if_incompatible));

MOCK_DECL(STATIC void, initiate_descriptor_downloads,
          (const routerstatus_t *source, int purpose, smartlist_t *digests,
           int lo, int hi, int pds_flags));

#endif /* defined(ROUTERLIST_PRIVATE) */

#endif /* !defined(TOR_ROUTERLIST_H) */
