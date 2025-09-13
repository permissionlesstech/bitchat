/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file networkstatus.h
 * \brief Header file for networkstatus.c.
 **/

#ifndef TOR_NETWORKSTATUS_H
#define TOR_NETWORKSTATUS_H

#include "lib/testsupport/testsupport.h"

void networkstatus_reset_warnings(void);
void networkstatus_reset_download_failures(void);
MOCK_DECL(char *,networkstatus_get_cache_fname,(int flav,
                                                const char *flavorname,
                                                int unverified_consensus));
tor_mmap_t *networkstatus_map_cached_consensus(const char *flavorname);
int router_reload_consensus_networkstatus(void);
void routerstatus_free_(routerstatus_t *rs);
#define routerstatus_free(rs) \
  FREE_AND_NULL(routerstatus_t, routerstatus_free_, (rs))
void networkstatus_vote_free_(networkstatus_t *ns);
#define networkstatus_vote_free(ns) \
  FREE_AND_NULL(networkstatus_t, networkstatus_vote_free_, (ns))
networkstatus_voter_info_t *networkstatus_get_voter_by_id(
                                       networkstatus_t *vote,
                                       const char *identity);
document_signature_t *networkstatus_get_voter_sig_by_alg(
                                    const networkstatus_voter_info_t *voter,
                                    digest_algorithm_t alg);

int networkstatus_check_consensus_signature(networkstatus_t *consensus,
                                            int warn);
int networkstatus_check_document_signature(const networkstatus_t *consensus,
                                           document_signature_t *sig,
                                           const authority_cert_t *cert);
int compare_digest_to_routerstatus_entry(const void *_key,
                                         const void **_member);
int compare_digest_to_vote_routerstatus_entry(const void *_key,
                                              const void **_member);
MOCK_DECL(const routerstatus_t *,networkstatus_vote_find_entry,(
                                              networkstatus_t *ns,
                                              const char *digest));
routerstatus_t *networkstatus_vote_find_mutable_entry(networkstatus_t *ns,
                                              const char *digest);
int networkstatus_vote_find_entry_idx(networkstatus_t *ns,
                                      const char *digest, int *found_out);

MOCK_DECL(download_status_t *,
  networkstatus_get_dl_status_by_flavor,
  (consensus_flavor_t flavor));
MOCK_DECL(download_status_t *,
  networkstatus_get_dl_status_by_flavor_bootstrap,
  (consensus_flavor_t flavor));
MOCK_DECL(download_status_t *,
  networkstatus_get_dl_status_by_flavor_running,
  (consensus_flavor_t flavor));

MOCK_DECL(smartlist_t *, router_get_descriptor_digests, (void));
MOCK_DECL(download_status_t *,router_get_dl_status_by_descriptor_digest,
          (const char *d));

const routerstatus_t *router_get_consensus_status_by_id(const char *digest);
routerstatus_t *router_get_mutable_consensus_status_by_id(
                                   const char *digest);
const routerstatus_t *router_get_consensus_status_by_descriptor_digest(
                                   networkstatus_t *consensus,
                                   const char *digest);
MOCK_DECL(routerstatus_t *,
          router_get_mutable_consensus_status_by_descriptor_digest,
          (networkstatus_t *consensus, const char *digest));
int we_want_to_fetch_flavor(const or_options_t *options, int flavor);
int we_want_to_fetch_unknown_auth_certs(const or_options_t *options);
void networkstatus_consensus_download_failed(int status_code,
                                             const char *flavname);
void update_consensus_networkstatus_fetch_time(time_t now);
int should_delay_dir_fetches(const or_options_t *options,const char **msg_out);
void update_networkstatus_downloads(time_t now);
void update_certificate_downloads(time_t now);
int consensus_is_waiting_for_certs(void);
int client_would_use_router(const routerstatus_t *rs, time_t now);
MOCK_DECL(networkstatus_t *,networkstatus_get_latest_consensus,(void));
MOCK_DECL(networkstatus_t *,networkstatus_get_latest_consensus_by_flavor,
          (consensus_flavor_t f));
MOCK_DECL(networkstatus_t *, networkstatus_get_live_consensus,(time_t now));
int networkstatus_is_live(const networkstatus_t *ns, time_t now);
int networkstatus_consensus_reasonably_live(const networkstatus_t *consensus,
                                            time_t now);
int networkstatus_valid_after_is_reasonably_live(time_t valid_after,
                                                 time_t now);
int networkstatus_valid_until_is_reasonably_live(time_t valid_until,
                                                 time_t now);
MOCK_DECL(networkstatus_t *,networkstatus_get_reasonably_live_consensus,
                                                        (time_t now,
                                                         int flavor));
MOCK_DECL(int, networkstatus_consensus_is_bootstrapping,(time_t now));
int networkstatus_consensus_can_use_multiple_directories(
                                                const or_options_t *options);
MOCK_DECL(int, networkstatus_consensus_can_use_extra_fallbacks,(
                                                const or_options_t *options));
int networkstatus_consensus_is_already_downloading(const char *resource);

#define NSSET_FROM_CACHE 1
#define NSSET_WAS_WAITING_FOR_CERTS 2
#define NSSET_DONT_DOWNLOAD_CERTS 4
#define NSSET_ACCEPT_OBSOLETE 8
#define NSSET_REQUIRE_FLAVOR 16
int networkstatus_set_current_consensus(const char *consensus,
                                        size_t consensus_len,
                                        const char *flavor,
                                        unsigned flags,
                                        const char *source_dir);
void networkstatus_note_certs_arrived(const char *source_dir);
void routers_update_all_from_networkstatus(time_t now, int dir_version);
void routers_update_status_from_consensus_networkstatus(smartlist_t *routers,
                                                        int reset_failures);
void signed_descs_update_status_from_consensus_networkstatus(
                                                         smartlist_t *descs);

char *networkstatus_getinfo_helper_single(const routerstatus_t *rs);
char *networkstatus_getinfo_by_purpose(const char *purpose_string, time_t now);
MOCK_DECL(int32_t, networkstatus_get_param,
          (const networkstatus_t *ns, const char *param_name,
           int32_t default_val, int32_t min_val, int32_t max_val));
int32_t networkstatus_get_overridable_param(const networkstatus_t *ns,
                                            int32_t torrc_value,
                                            const char *param_name,
                                            int32_t default_val,
                                            int32_t min_val, int32_t max_val);
int getinfo_helper_networkstatus(control_connection_t *conn,
                                 const char *question, char **answer,
                                 const char **errmsg);
int32_t networkstatus_get_bw_weight(networkstatus_t *ns, const char *weight,
                                    int32_t default_val);
const char *networkstatus_get_flavor_name(consensus_flavor_t flav);
int networkstatus_parse_flavor_name(const char *flavname);
void document_signature_free_(document_signature_t *sig);
#define document_signature_free(sig) \
  FREE_AND_NULL(document_signature_t, document_signature_free_, (sig))
document_signature_t *document_signature_dup(const document_signature_t *sig);
void networkstatus_free_all(void);
int networkstatus_get_weight_scale_param(networkstatus_t *ns);

void vote_routerstatus_free_(vote_routerstatus_t *rs);
#define vote_routerstatus_free(rs) \
  FREE_AND_NULL(vote_routerstatus_t, vote_routerstatus_free_, (rs))

void set_routerstatus_from_routerinfo(routerstatus_t *rs,
                                      const node_t *node,
                                      const routerinfo_t *ri);
time_t voting_sched_get_start_of_interval_after(time_t now,
                                                  int interval,
                                                  int offset);

#ifdef NETWORKSTATUS_PRIVATE
#ifdef TOR_UNIT_TESTS
STATIC int networkstatus_set_current_consensus_from_ns(networkstatus_t *c,
                                                const char *flavor);
STATIC void warn_early_consensus(const networkstatus_t *c, const char *flavor,
                                 time_t now);
extern networkstatus_t *current_ns_consensus;
extern networkstatus_t *current_md_consensus;
#endif /* defined(TOR_UNIT_TESTS) */
STATIC int routerstatus_has_visibly_changed(const routerstatus_t *a,
                                    const routerstatus_t *b);
#endif /* defined(NETWORKSTATUS_PRIVATE) */

#endif /* !defined(TOR_NETWORKSTATUS_H) */
