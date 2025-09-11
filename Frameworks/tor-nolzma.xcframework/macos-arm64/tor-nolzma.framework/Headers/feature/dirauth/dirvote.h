/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dirvote.h
 * \brief Header file for dirvote.c.
 **/

#ifndef TOR_DIRVOTE_H
#define TOR_DIRVOTE_H

/*
 * Ideally, assuming synced clocks, we should only need 1 second for each of:
 *  - Vote
 *  - Distribute
 *  - Consensus Publication
 * As we can gather descriptors continuously.
 * (Could we even go as far as publishing the previous consensus,
 *  in the same second that we vote for the next one?)
 * But we're not there yet: these are the lowest working values at this time.
 */

/** Lowest allowable value for VoteSeconds. */
#define MIN_VOTE_SECONDS 2
/** Lowest allowable value for VoteSeconds when TestingTorNetwork is 1 */
#define MIN_VOTE_SECONDS_TESTING 2

/** Lowest allowable value for DistSeconds. */
#define MIN_DIST_SECONDS 2
/** Lowest allowable value for DistSeconds when TestingTorNetwork is 1 */
#define MIN_DIST_SECONDS_TESTING 2

/** Lowest allowable voting interval. */
#define MIN_VOTE_INTERVAL 300
/** Lowest allowable voting interval when TestingTorNetwork is 1:
 * Voting Interval can be:
 *   10, 12, 15, 18, 20, 24, 25, 30, 36, 40, 45, 50, 60, ...
 * Testing Initial Voting Interval can be:
 *    5,  6,  8,  9, or any of the possible values for Voting Interval,
 * as they both need to evenly divide 30 minutes.
 * If clock desynchronisation is an issue, use an interval of at least:
 *   18 * drift in seconds, to allow for a clock slop factor */
#define MIN_VOTE_INTERVAL_TESTING \
                (((MIN_VOTE_SECONDS_TESTING)+(MIN_DIST_SECONDS_TESTING)+1)*2)

#define MIN_VOTE_INTERVAL_TESTING_INITIAL \
                ((MIN_VOTE_SECONDS_TESTING)+(MIN_DIST_SECONDS_TESTING)+1)

/** The lowest consensus method that we currently support. */
#define MIN_SUPPORTED_CONSENSUS_METHOD 28

/** The highest consensus method that we currently support. */
#define MAX_SUPPORTED_CONSENSUS_METHOD 33

/**
 * Lowest consensus method where microdescriptor lines are put in canonical
 * form for improved compressibility and ease of storage. See proposal 298.
 **/
#define MIN_METHOD_FOR_CANONICAL_FAMILIES_IN_MICRODESCS 29

/** Lowest consensus method where an unpadded base64 onion-key-ntor is allowed
 * See #7869 */
#define MIN_METHOD_FOR_UNPADDED_NTOR_KEY 30

/** Lowest consensus method for which we use the correct algorithm for
 * extracting the bwweightscale= and maxunmeasuredbw= parameters. See #19011.
 */
#define MIN_METHOD_FOR_CORRECT_BWWEIGHTSCALE 31

/** Lowest consensus method for which we handle the MiddleOnly flag specially.
 */
#define MIN_METHOD_FOR_MIDDLEONLY 32

/**
 * Lowest consensus method for which we suppress the published time in
 * microdescriptor consensuses.
 */
#define MIN_METHOD_TO_SUPPRESS_MD_PUBLISHED 33

/** Default bandwidth to clip unmeasured bandwidths to using method >=
 * MIN_METHOD_TO_CLIP_UNMEASURED_BW.  (This is not a consensus method; do not
 * get confused with the above macros.) */
#define DEFAULT_MAX_UNMEASURED_BW_KB 20

/* Directory Get Vote (DGV) flags for dirvote_get_vote(). */
#define DGV_BY_ID 1
#define DGV_INCLUDE_PENDING 2
#define DGV_INCLUDE_PREVIOUS 4

/** Maximum size of a line in a vote. */
#define MAX_BW_FILE_HEADERS_LINE_LEN 1024

extern const char DIRVOTE_UNIVERSAL_FLAGS[];
extern const char DIRVOTE_OPTIONAL_FLAGS[];

/*
 * Public API. Used outside of the dirauth subsystem.
 *
 * We need to nullify them if the module is disabled.
 */
#ifdef HAVE_MODULE_DIRAUTH

time_t dirvote_act(const or_options_t *options, time_t now);
void dirvote_free_all(void);

void dirvote_parse_sr_commits(networkstatus_t *ns, const smartlist_t *tokens);
void dirvote_clear_commits(networkstatus_t *ns);
void dirvote_dirreq_get_status_vote(const char *url, smartlist_t *items,
                                    smartlist_t *dir_items);

/* Storing signatures and votes functions */
struct pending_vote_t * dirvote_add_vote(const char *vote_body,
                                         time_t time_posted,
                                         const char *where_from,
                                         const char **msg_out,
                                         int *status_out);
int dirvote_add_signatures(const char *detached_signatures_body,
                           const char *source,
                           const char **msg_out);

struct config_line_t;
char *format_recommended_version_list(const struct config_line_t *line,
                                      int warn);

#else /* !defined(HAVE_MODULE_DIRAUTH) */

static inline time_t
dirvote_act(const or_options_t *options, time_t now)
{
  (void) options;
  (void) now;
  return TIME_MAX;
}

static inline void
dirvote_free_all(void)
{
}

static inline void
dirvote_parse_sr_commits(networkstatus_t *ns, const smartlist_t *tokens)
{
  (void) ns;
  (void) tokens;
}

static inline void
dirvote_clear_commits(networkstatus_t *ns)
{
  (void) ns;
}

static inline void
dirvote_dirreq_get_status_vote(const char *url, smartlist_t *items,
                               smartlist_t *dir_items)
{
  (void) url;
  (void) items;
  (void) dir_items;
}

static inline struct pending_vote_t *
dirvote_add_vote(const char *vote_body,
                 time_t time_posted,
                 const char *where_from,
                 const char **msg_out,
                 int *status_out)
{
  (void) vote_body;
  (void) time_posted;
  (void) where_from;
  /* If the dirauth module is disabled, this should NEVER be called else we
   * failed to safeguard the dirauth module. */
  tor_assert_nonfatal_unreached();

  /* We need to send out an error code. */
  *status_out = 400;
  *msg_out = "No directory authority support";
  return NULL;
}

static inline int
dirvote_add_signatures(const char *detached_signatures_body,
                       const char *source,
                       const char **msg_out)
{
  (void) detached_signatures_body;
  (void) source;
  *msg_out = "No directory authority support";
  /* If the dirauth module is disabled, this should NEVER be called else we
   * failed to safeguard the dirauth module. */
  tor_assert_nonfatal_unreached();
  return 0;
}

#endif /* defined(HAVE_MODULE_DIRAUTH) */

/* Item access */
MOCK_DECL(const char*, dirvote_get_pending_consensus,
          (consensus_flavor_t flav));
MOCK_DECL(uint32_t,dirserv_get_bandwidth_for_router_kb,
        (const routerinfo_t *ri));
MOCK_DECL(const char*, dirvote_get_pending_detached_signatures, (void));
const cached_dir_t *dirvote_get_vote(const char *fp, int flags);

/*
 * API used _only_ by the dirauth subsystem.
 */

networkstatus_t *
dirserv_generate_networkstatus_vote_obj(crypto_pk_t *private_key,
                                        authority_cert_t *cert);

vote_microdesc_hash_t *dirvote_format_all_microdesc_vote_lines(
                                        const routerinfo_t *ri,
                                        time_t now,
                                        smartlist_t *microdescriptors_out);

/*
 * Exposed functions for unit tests.
 */
#ifdef DIRVOTE_PRIVATE

/* Cert manipulation */
STATIC authority_cert_t *authority_cert_dup(authority_cert_t *cert);
STATIC int32_t dirvote_get_intermediate_param_value(
                                   const smartlist_t *param_list,
                                   const char *keyword,
                                   int32_t default_val);
STATIC char *format_networkstatus_vote(crypto_pk_t *private_key,
                                 networkstatus_t *v3_ns);
STATIC smartlist_t *dirvote_compute_params(smartlist_t *votes, int method,
                             int total_authorities);
STATIC char *compute_consensus_package_lines(smartlist_t *votes);
STATIC char *make_consensus_method_list(int low, int high, const char *sep);
STATIC int
networkstatus_compute_bw_weights_v10(smartlist_t *chunks, int64_t G,
                                     int64_t M, int64_t E, int64_t D,
                                     int64_t T, int64_t weight_scale);
STATIC
char *networkstatus_compute_consensus(smartlist_t *votes,
                                      int total_authorities,
                                      crypto_pk_t *identity_key,
                                      crypto_pk_t *signing_key,
                                      const char *legacy_identity_key_digest,
                                      crypto_pk_t *legacy_signing_key,
                                      consensus_flavor_t flavor);
STATIC
int networkstatus_add_detached_signatures(networkstatus_t *target,
                                          ns_detached_signatures_t *sigs,
                                          const char *source,
                                          int severity,
                                          const char **msg_out);
STATIC int
compare_routerinfo_usefulness(const routerinfo_t *first,
                              const routerinfo_t *second);
STATIC
int compare_routerinfo_by_ipv4(const void **a, const void **b);

STATIC
int compare_routerinfo_by_ipv6(const void **a, const void **b);

STATIC
digestmap_t * get_sybil_list_by_ip_version(
    const smartlist_t *routers, sa_family_t family);

STATIC
digestmap_t * get_all_possible_sybil(const smartlist_t *routers);

STATIC
char *networkstatus_get_detached_signatures(smartlist_t *consensuses);
STATIC microdesc_t *dirvote_create_microdescriptor(const routerinfo_t *ri,
                                                   int consensus_method);
STATIC int64_t extract_param_buggy(const char *params,
                                   const char *param_name,
                                   int64_t default_value);

#endif /* defined(DIRVOTE_PRIVATE) */

#endif /* !defined(TOR_DIRVOTE_H) */
