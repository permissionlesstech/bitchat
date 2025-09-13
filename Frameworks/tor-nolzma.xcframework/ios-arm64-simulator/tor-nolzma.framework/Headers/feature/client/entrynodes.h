/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file entrynodes.h
 * \brief Header file for circuitbuild.c.
 **/

#ifndef TOR_ENTRYNODES_H
#define TOR_ENTRYNODES_H

#include "lib/container/handles.h"

/* Forward declare for guard_selection_t; entrynodes.c has the real struct */
typedef struct guard_selection_t guard_selection_t;

/* Forward declare for entry_guard_t; the real declaration is private. */
typedef struct entry_guard_t entry_guard_t;

/* Forward declaration for circuit_guard_state_t; the real declaration is
   private. */
typedef struct circuit_guard_state_t circuit_guard_state_t;

/* Forward declaration for entry_guard_restriction_t; the real declaration is
   private. */
typedef struct entry_guard_restriction_t entry_guard_restriction_t;

/** Information about a guard's pathbias status.
 * These fields are used in circpathbias.c to try to detect entry
 * nodes that are failing circuits at a suspicious frequency.
 */
typedef struct guard_pathbias_t {
  unsigned int path_bias_noticed : 1; /**< Did we alert the user about path
                                       * bias for this node already? */
  unsigned int path_bias_warned : 1; /**< Did we alert the user about path bias
                                      * for this node already? */
  unsigned int path_bias_extreme : 1; /**< Did we alert the user about path
                                       * bias for this node already? */
  unsigned int path_bias_disabled : 1; /**< Have we disabled this node because
                                        * of path bias issues? */
  unsigned int path_bias_use_noticed : 1; /**< Did we alert the user about path
                                       * use bias for this node already? */
  unsigned int path_bias_use_extreme : 1; /**< Did we alert the user about path
                                       * use bias for this node already? */

  double circ_attempts; /**< Number of circuits this guard has "attempted" */
  double circ_successes; /**< Number of successfully built circuits using
                               * this guard as first hop. */
  double successful_circuits_closed; /**< Number of circuits that carried
                                        * streams successfully. */
  double collapsed_circuits; /**< Number of fully built circuits that were
                                 * remotely closed before any streams were
                                 * attempted. */
  double unusable_circuits; /**< Number of circuits for which streams were
                                *  attempted, but none succeeded. */
  double timeouts; /**< Number of 'right-censored' circuit timeouts for this
                       * guard. */
  double use_attempts; /**< Number of circuits we tried to use with streams */
  double use_successes; /**< Number of successfully used circuits using
                               * this guard as first hop. */
} guard_pathbias_t;

#if defined(ENTRYNODES_PRIVATE)
#include "lib/crypt_ops/crypto_ed25519.h"

/**
 * @name values for entry_guard_t.is_reachable.
 *
 * See entry_guard_t.is_reachable for more information.
 */
/**@{*/
#define GUARD_REACHABLE_NO    0
#define GUARD_REACHABLE_YES   1
#define GUARD_REACHABLE_MAYBE 2
/**@}*/

/** An entry_guard_t represents our information about a chosen long-term
 * first hop, known as a "helper" node in the literature. We can't just
 * use a node_t, since we want to remember these even when we
 * don't have any directory info. */
struct entry_guard_t {
  HANDLE_ENTRY(entry_guard, entry_guard_t);

  char nickname[MAX_HEX_NICKNAME_LEN+1];
  char identity[DIGEST_LEN];
  ed25519_public_key_t ed_id;

  /**
   * @name new guard selection algorithm fields.
   *
   * Only the new (prop271) algorithm uses these.  For a more full
   * description of the algorithm, see the module documentation for
   * entrynodes.c
   */
  /**@{*/

  /* == Persistent fields, present for all sampled guards. */
  /** When was this guard added to the sample? */
  time_t sampled_on_date;
  /** Since what date has this guard been "unlisted"?  A guard counts as
   * unlisted if we have a live consensus that does not include it, or
   * if we have a live consensus that does not include it as a usable
   * guard.  This field is zero when the guard is listed. */
  time_t unlisted_since_date; // can be zero
  /** What version of Tor added this guard to the sample? */
  char *sampled_by_version;
  /** Is this guard listed right now? If this is set, then
   * unlisted_since_date should be set too. */
  unsigned currently_listed : 1;

  /* == Persistent fields, for confirmed guards only */
  /** When was this guard confirmed? (That is, when did we first use it
   * successfully and decide to keep it?) This field is zero if this is not a
   * confirmed guard. */
  time_t confirmed_on_date; /* 0 if not confirmed */
  /**
   * In what order was this guard sampled? Guards with
   * lower indices appear earlier on the sampled list, the confirmed list and
   * the primary list as a result of Prop 310
   */
  int sampled_idx;

  /**
   * In what order was this guard confirmed? Guards with lower indices
   * appear earlier on the confirmed list.  If the confirmed list is compacted,
   * this field corresponds to the index of this guard on the confirmed list.
   *
   * This field is set to -1 if this guard is not confirmed.
   */
  int confirmed_idx; /* -1 if not confirmed; otherwise the order that this
                      * item should occur in the CONFIRMED_GUARDS ordered
                      * list */

  /**
   * Which selection does this guard belong to?
   */
  char *selection_name;

  /** Bridges only: address of the bridge. */
  tor_addr_port_t *bridge_addr;

  /* ==== Non-persistent fields. */
  /* == These are used by sampled guards */
  /** When did we last decide to try using this guard for a circuit? 0 for
   * "not since we started up." */
  time_t last_tried_to_connect;
  /** How reachable do we consider this guard to be? One of
   * GUARD_REACHABLE_NO, GUARD_REACHABLE_YES, or GUARD_REACHABLE_MAYBE. */
  unsigned is_reachable : 2;
  /** Boolean: true iff this guard is pending. A pending guard is one
   * that we have an in-progress circuit through, and which we do not plan
   * to try again until it either succeeds or fails. Primary guards can
   * never be pending. */
  unsigned is_pending : 1;
  /** If true, don't write this guard to disk. (Used for bridges with unknown
   * identities) */
  unsigned is_persistent : 1;
  /** When did we get the earliest connection failure for this guard?
   * We clear this field on a successful connect.  We do _not_ clear it
   * when we mark the guard as "MAYBE" reachable.
   */
  time_t failing_since;

  /* == Set inclusion flags. */
  /** If true, this guard is in the filtered set.  The filtered set includes
   * all sampled guards that our configuration allows us to use. */
  unsigned is_filtered_guard : 1;
  /** If true, this guard is in the usable filtered set. The usable filtered
   * set includes all filtered guards that are not believed to be
   * unreachable. (That is, those for which is_reachable is not
   * GUARD_REACHABLE_NO) */
  unsigned is_usable_filtered_guard : 1;
  unsigned is_primary:1;

  /** This string holds any fields that we are maintaining because
   * we saw them in the state, even if we don't understand them. */
  char *extra_state_fields;

  /** Backpointer to the guard selection that this guard belongs to.
   * The entry_guard_t must never outlive its guard_selection. */
  guard_selection_t *in_selection;
  /**@}*/

  /** Path bias information for this guard. */
  guard_pathbias_t pb;
};

/**
 * Possible rules for a guard selection to follow
 */
typedef enum guard_selection_type_t {
  /** Infer the type of this selection from its name. */
  GS_TYPE_INFER=0,
  /** Use the normal guard selection algorithm, taking our sample from the
   * complete list of guards in the consensus. */
  GS_TYPE_NORMAL=1,
  /** Use the normal guard selection algorithm, taking our sample from the
   * configured bridges, and allowing it to grow as large as all the configured
   * bridges */
  GS_TYPE_BRIDGE,
  /** Use the normal guard selection algorithm, taking our sample from the
   * set of filtered nodes. */
  GS_TYPE_RESTRICTED,
} guard_selection_type_t;

/**
 * All of the the context for guard selection on a particular client.
 *
 * We maintain multiple guard selection contexts for a client, depending
 * aspects on its current configuration -- whether an extremely
 * restrictive EntryNodes is used, whether UseBridges is enabled, and so
 * on.)
 *
 * See the module documentation for entrynodes.c for more information
 * about guard selection algorithms.
 */
struct guard_selection_t {
  /**
   * The name for this guard-selection object. (Must not contain spaces).
   */
  char *name;

  /**
   * What rules does this guard-selection object follow?
   */
  guard_selection_type_t type;

  /**
   * A value of 1 means that primary_entry_guards is up-to-date with respect to
   * the consensus and status info that we currently have; 0 means we need to
   * recalculate it before using primary_entry_guards or the is_primary flag on
   * any guard.
   */
  int primary_guards_up_to_date;

  /**
   * A list of the sampled entry guards, as entry_guard_t structures.
   * Not in any particular order.  When we 'sample' a guard, we are
   * noting it as a possible guard to pick in the future. The use of
   * sampling here prevents us from being forced by an attacker to try
   * every guard on the network. This list is persistent.
   */
  smartlist_t *sampled_entry_guards;

  /**
   * Ordered list (from highest to lowest priority) of guards that we
   * have successfully contacted and decided to use. Every member of
   * this list is a member of sampled_entry_guards. Every member should
   * have confirmed_on_date set.
   * The ordering of the list should be by sampled idx. The reasoning behind
   * it is linked to Proposal 310.
   *
   * This list is persistent. It is a subset of the elements in
   * sampled_entry_guards, and its pointers point to elements of
   * sampled_entry_guards.
   */
  smartlist_t *confirmed_entry_guards;

  /**
   * Ordered list (from highest to lowest priority) of guards that we
   * are willing to use the most happily.  These guards may or may not
   * yet be confirmed yet.  If we can use one of these guards, we are
   * probably not on a network that is trying to restrict our guard
   * choices.
   *
   * This list is a subset of the elements in
   * sampled_entry_guards, and its pointers point to elements of
   * sampled_entry_guards.
   */
  smartlist_t *primary_entry_guards;

  /** When did we last successfully build a circuit or use a circuit? */
  time_t last_time_on_internet;

  /** What confirmed_idx value should the next-added member of
   * confirmed_entry_guards receive? */
  int next_confirmed_idx;

  /** What sampled_idx value should the next-added member of
   * sampled_entry_guards receive? This should follow the size of the sampled
   * list until sampled relays get pruned for some reason
   */
  int next_sampled_idx;

};

struct entry_guard_handle_t;

/** Types of restrictions we impose when picking guard nodes */
typedef enum guard_restriction_type_t {
  /* Don't pick the same guard node as our exit node (or its family) */
  RST_EXIT_NODE = 0,
  /* Don't pick dirguards that have previously shown to be outdated */
  RST_OUTDATED_MD_DIRSERVER = 1,
  /* Don't pick guards if they are in the exclusion list */
  RST_EXCL_LIST = 2,
} guard_restriction_type_t;

/**
 * A restriction to remember which entry guards are off-limits for a given
 * circuit.
 *
 * Note: This mechanism is NOT for recording which guards are never to be
 * used: only which guards cannot be used on <em>one particular circuit</em>.
 */
struct entry_guard_restriction_t {
  /* What type of restriction are we imposing? */
  guard_restriction_type_t type;

  /* In case of restriction type RST_EXIT_NODE, the guard's RSA identity
   * digest must not equal this; and it must not be in the same family as any
   * node with this digest. */
  uint8_t exclude_id[DIGEST_LEN];

  /* In the case of RST_EXCL_LIST, any identity digests in this list
   * must not be used. */
  smartlist_t *excluded;
};

/**
 * Per-circuit state to track whether we'll be able to use the circuit.
 */
struct circuit_guard_state_t {
  /** Handle to the entry guard object for this circuit. */
  struct entry_guard_handle_t *guard;
  /** The time at which <b>state</b> last changed. */
  time_t state_set_at;
  /** One of GUARD_CIRC_STATE_* */
  uint8_t state;

  /**
   * A set of restrictions that were placed on this guard when we selected it
   * for this particular circuit.  We need to remember the restrictions here,
   * since any guard that breaks these restrictions will not block this
   * circuit from becoming COMPLETE.
   */
  entry_guard_restriction_t *restrictions;
};
#endif /* defined(ENTRYNODES_PRIVATE) */

/* Common entry points for old and new guard code */
int guards_update_all(void);
const node_t *guards_choose_guard(const origin_circuit_t *circ,
                                  cpath_build_state_t *state,
                                  uint8_t purpose,
                                  circuit_guard_state_t **guard_state_out);
const node_t *guards_choose_dirguard(uint8_t dir_purpose,
                                     circuit_guard_state_t **guard_state_out);

#if 1
/* XXXX NM I would prefer that all of this stuff be private to
 * entrynodes.c. */
entry_guard_t *entry_guard_get_by_id_digest_for_guard_selection(
    guard_selection_t *gs, const char *digest);
entry_guard_t *entry_guard_get_by_id_digest(const char *digest);

circuit_guard_state_t *
get_guard_state_for_bridge_desc_fetch(const char *digest);

void entry_guards_changed_for_guard_selection(guard_selection_t *gs);
void entry_guards_changed(void);
guard_selection_t * get_guard_selection_info(void);
int num_live_entry_guards_for_guard_selection(
    guard_selection_t *gs,
    int for_directory);
int num_live_entry_guards(int for_directory);
#endif /* 1 */

const node_t *entry_guard_find_node(const entry_guard_t *guard);
const char *entry_guard_get_rsa_id_digest(const entry_guard_t *guard);
const char *entry_guard_describe(const entry_guard_t *guard);
guard_pathbias_t *entry_guard_get_pathbias_state(entry_guard_t *guard);

/** Enum to specify how we're going to use a given guard, when we're picking
 * one for immediate use. */
typedef enum {
  GUARD_USAGE_TRAFFIC = 0,
  GUARD_USAGE_DIRGUARD = 1
} guard_usage_t;

#define circuit_guard_state_free(val) \
  FREE_AND_NULL(circuit_guard_state_t, circuit_guard_state_free_, (val))

void circuit_guard_state_free_(circuit_guard_state_t *state);
int entry_guard_pick_for_circuit(guard_selection_t *gs,
                                 guard_usage_t usage,
                                 entry_guard_restriction_t *rst,
                                 const node_t **chosen_node_out,
                                 circuit_guard_state_t **guard_state_out);

/* We just connected to an entry guard. What should we do with the circuit? */
typedef enum {
  GUARD_USABLE_NEVER = -1, /* Never use the circuit */
  GUARD_MAYBE_USABLE_LATER = 0, /* Keep it. We might use it in the future */
  GUARD_USABLE_NOW = 1, /* Use it right now */
} guard_usable_t;

guard_usable_t entry_guard_succeeded(circuit_guard_state_t **guard_state_p);
void entry_guard_failed(circuit_guard_state_t **guard_state_p);
void entry_guard_cancel(circuit_guard_state_t **guard_state_p);
void entry_guard_chan_failed(channel_t *chan);
int entry_guards_update_all(guard_selection_t *gs);
int entry_guards_upgrade_waiting_circuits(guard_selection_t *gs,
                                          const smartlist_t *all_circuits,
                                          smartlist_t *newly_complete_out);
int entry_guard_state_should_expire(circuit_guard_state_t *guard_state);
void entry_guards_note_internet_connectivity(guard_selection_t *gs);

int update_guard_selection_choice(const or_options_t *options);

int entry_guard_could_succeed(const circuit_guard_state_t *guard_state);

MOCK_DECL(int,num_bridges_usable,(int use_maybe_reachable));

#ifdef ENTRYNODES_PRIVATE
/**
 * @name Default values for the parameters for the new (prop271) entry guard
 * algorithm.
 */
/**@{*/
/**
 * We never let our sampled guard set grow larger than this percentage
 * of the guards on the network.
 */
#define DFLT_MAX_SAMPLE_THRESHOLD_PERCENT 20
/**
 * We never let our sampled guard set grow larger than this number of
 * guards.
 */
#define DFLT_MAX_SAMPLE_SIZE 60
/**
 * We always try to make our sample contain at least this many guards.
 */
#define DFLT_MIN_FILTERED_SAMPLE_SIZE 20
/**
 * If a guard is unlisted for this many days in a row, we remove it.
 */
#define DFLT_REMOVE_UNLISTED_GUARDS_AFTER_DAYS 20
/**
 * We remove unconfirmed guards from the sample after this many days,
 * regardless of whether they are listed or unlisted.
 */
#define DFLT_GUARD_LIFETIME_DAYS 120
/**
 * We remove confirmed guards from the sample if they were sampled
 * GUARD_LIFETIME_DAYS ago and confirmed this many days ago.
 */
#define DFLT_GUARD_CONFIRMED_MIN_LIFETIME_DAYS 60
/**
 * How many guards do we try to keep on our primary guard list?
 */
#define DFLT_N_PRIMARY_GUARDS 3
/**
 * Of the live guards on the primary guard list, how many do we consider when
 * choosing a guard to use?
 */
#define DFLT_N_PRIMARY_GUARDS_TO_USE 1
/**
 * As DFLT_N_PRIMARY_GUARDS, but for choosing which directory guard to use.
 */
#define DFLT_N_PRIMARY_DIR_GUARDS_TO_USE 3
/**
 * If we haven't successfully built or used a circuit in this long, then
 * consider that the internet is probably down.
 */
#define DFLT_INTERNET_LIKELY_DOWN_INTERVAL (10*60)
/**
 * If we're trying to connect to a nonprimary guard for at least this
 * many seconds, and we haven't gotten the connection to work, we will treat
 * lower-priority guards as usable.
 */
#define DFLT_NONPRIMARY_GUARD_CONNECT_TIMEOUT 15
/**
 * If a circuit has been sitting around in 'waiting for better guard' state
 * for at least this long, we'll expire it.
 */
#define DFLT_NONPRIMARY_GUARD_IDLE_TIMEOUT (10*60)
/**
 * If our configuration retains fewer than this fraction of guards from the
 * torrc, we are in a restricted setting.
 */
#define DFLT_MEANINGFUL_RESTRICTION_PERCENT 20
/**
 * If our configuration retains fewer than this fraction of guards from the
 * torrc, we are in an extremely restricted setting, and should warn.
 */
#define DFLT_EXTREME_RESTRICTION_PERCENT 1
/**@}*/

STATIC double get_max_sample_threshold(void);
STATIC int get_max_sample_size_absolute(void);
STATIC int get_min_filtered_sample_size(void);
STATIC int get_remove_unlisted_guards_after_days(void);
STATIC int get_guard_lifetime(void);
STATIC int get_guard_confirmed_min_lifetime(void);
STATIC int get_n_primary_guards(void);
STATIC int get_n_primary_guards_to_use(guard_usage_t usage);
STATIC int get_internet_likely_down_interval(void);
STATIC int get_nonprimary_guard_connect_timeout(void);
STATIC int get_nonprimary_guard_idle_timeout(void);
STATIC double get_meaningful_restriction_threshold(void);
STATIC double get_extreme_restriction_threshold(void);

HANDLE_DECL(entry_guard, entry_guard_t, STATIC)
#define entry_guard_handle_free(h)    \
  FREE_AND_NULL(entry_guard_handle_t, entry_guard_handle_free_, (h))

STATIC guard_selection_type_t guard_selection_infer_type(
                           guard_selection_type_t type_in,
                           const char *name);
STATIC guard_selection_t *guard_selection_new(const char *name,
                                              guard_selection_type_t type);
STATIC guard_selection_t *get_guard_selection_by_name(
          const char *name, guard_selection_type_t type, int create_if_absent);
STATIC void guard_selection_free_(guard_selection_t *gs);
#define guard_selection_free(gs) \
  FREE_AND_NULL(guard_selection_t, guard_selection_free_, (gs))
MOCK_DECL(STATIC int, entry_guard_is_listed,
          (guard_selection_t *gs, const entry_guard_t *guard));
STATIC const char *choose_guard_selection(const or_options_t *options,
                                        const networkstatus_t *ns,
                                        const guard_selection_t *old_selection,
                                        guard_selection_type_t *type_out);
STATIC entry_guard_t *get_sampled_guard_with_id(guard_selection_t *gs,
                                                const uint8_t *rsa_id);

MOCK_DECL(STATIC time_t, randomize_time, (time_t now, time_t max_backdate));

MOCK_DECL(STATIC circuit_guard_state_t *,
          circuit_guard_state_new,(entry_guard_t *guard, unsigned state,
                                   entry_guard_restriction_t *rst));

STATIC entry_guard_t *entry_guard_add_to_sample(guard_selection_t *gs,
                                                const node_t *node);
STATIC entry_guard_t *entry_guards_expand_sample(guard_selection_t *gs);
STATIC char *entry_guard_encode_for_state(entry_guard_t *guard, int
    dense_sampled_index);
STATIC entry_guard_t *entry_guard_parse_from_state(const char *s);
#define entry_guard_free(e) \
  FREE_AND_NULL(entry_guard_t, entry_guard_free_, (e))
STATIC void entry_guard_free_(entry_guard_t *e);
STATIC void entry_guards_update_filtered_sets(guard_selection_t *gs);
STATIC int entry_guards_all_primary_guards_are_down(guard_selection_t *gs);
/**
 * @name Flags for first_reachable_filtered_entry_guard()
 */
/**@{*/
#define SAMPLE_EXCLUDE_CONFIRMED   (1u<<0)
#define SAMPLE_EXCLUDE_PRIMARY     (1u<<1)
#define SAMPLE_EXCLUDE_PENDING     (1u<<2)
#define SAMPLE_NO_UPDATE_PRIMARY   (1u<<3)
#define SAMPLE_EXCLUDE_NO_DESCRIPTOR (1u<<4)
/**@}*/
STATIC entry_guard_t *first_reachable_filtered_entry_guard(
                                    guard_selection_t *gs,
                                    const entry_guard_restriction_t *rst,
                                    unsigned flags);
STATIC void entry_guard_consider_retry(entry_guard_t *guard);
STATIC void make_guard_confirmed(guard_selection_t *gs, entry_guard_t *guard);
STATIC void entry_guards_update_confirmed(guard_selection_t *gs);
STATIC void entry_guards_update_primary(guard_selection_t *gs);
STATIC int num_reachable_filtered_guards(const guard_selection_t *gs,
                                         const entry_guard_restriction_t *rst);
STATIC void sampled_guards_update_from_consensus(guard_selection_t *gs);
/**
 * @name Possible guard-states for a circuit.
 */
/**@{*/
/** State for a circuit that can (so far as the guard subsystem is
 * concerned) be used for actual traffic as soon as it is successfully
 * opened. */
#define GUARD_CIRC_STATE_USABLE_ON_COMPLETION 1
/** State for an non-open circuit that we shouldn't use for actual
 * traffic, when it completes, unless other circuits to preferable
 * guards fail. */
#define GUARD_CIRC_STATE_USABLE_IF_NO_BETTER_GUARD 2
/** State for an open circuit that we shouldn't use for actual traffic
 * unless other circuits to preferable guards fail. */
#define GUARD_CIRC_STATE_WAITING_FOR_BETTER_GUARD 3
/** State for a circuit that can (so far as the guard subsystem is
 * concerned) be used for actual traffic. */
#define GUARD_CIRC_STATE_COMPLETE 4
/** State for a circuit that is unusable, and will not become usable. */
#define GUARD_CIRC_STATE_DEAD 5
/**@}*/
STATIC void entry_guards_note_guard_failure(guard_selection_t *gs,
                                            entry_guard_t *guard);
STATIC entry_guard_t *select_entry_guard_for_circuit(guard_selection_t *gs,
                                          guard_usage_t usage,
                                          const entry_guard_restriction_t *rst,
                                          unsigned *state_out);
STATIC void mark_primary_guards_maybe_reachable(guard_selection_t *gs);
STATIC unsigned entry_guards_note_guard_success(guard_selection_t *gs,
                                                entry_guard_t *guard,
                                                unsigned old_state);
STATIC int entry_guard_has_higher_priority(entry_guard_t *a, entry_guard_t *b);
STATIC char *getinfo_helper_format_single_entry_guard(const entry_guard_t *e);

STATIC entry_guard_restriction_t *guard_create_exit_restriction(
                                                      const uint8_t *exit_id);

STATIC entry_guard_restriction_t *guard_create_dirserver_md_restriction(void);

STATIC entry_guard_restriction_t * guard_create_conflux_restriction(
                   const origin_circuit_t *circ);

STATIC void entry_guard_restriction_free_(entry_guard_restriction_t *rst);
#define entry_guard_restriction_free(rst)  \
  FREE_AND_NULL(entry_guard_restriction_t, \
                entry_guard_restriction_free_, (rst))

#endif /* defined(ENTRYNODES_PRIVATE) */

void remove_all_entry_guards_for_guard_selection(guard_selection_t *gs);
void remove_all_entry_guards(void);

struct bridge_info_t;
void entry_guard_learned_bridge_identity(const tor_addr_port_t *addrport,
                                         const uint8_t *rsa_id_digest);

int entry_list_is_constrained(const or_options_t *options);
int guards_retry_optimistic(const or_options_t *options);
int entry_guards_parse_state_for_guard_selection(
    guard_selection_t *gs, or_state_t *state, int set, char **msg);
int entry_guards_parse_state(or_state_t *state, int set, char **msg);
void entry_guards_update_state(or_state_t *state);
int getinfo_helper_entry_guards(control_connection_t *conn,
                                const char *question, char **answer,
                                const char **errmsg);

int entries_known_but_down(const or_options_t *options);
void entries_retry_all(const or_options_t *options);

char *entry_guards_get_err_str_if_dir_info_missing(int using_mds,
                                           int num_present, int num_usable);
char *guard_selection_get_err_str_if_dir_info_missing(guard_selection_t *gs,
                                              int using_mds,
                                              int num_present, int num_usable);

void entry_guards_free_all(void);

double pathbias_get_close_success_count(entry_guard_t *guard);
double pathbias_get_use_success_count(entry_guard_t *guard);

/** Contains the bandwidth of a relay as a guard and as a non-guard
 *  after the guardfraction has been considered. */
typedef struct guardfraction_bandwidth_t {
  /** Bandwidth as a guard after guardfraction has been considered. */
  int guard_bw;
  /** Bandwidth as a non-guard after guardfraction has been considered. */
  int non_guard_bw;
} guardfraction_bandwidth_t;

int should_apply_guardfraction(const networkstatus_t *ns);

void
guard_get_guardfraction_bandwidth(guardfraction_bandwidth_t *guardfraction_bw,
                                  int orig_bandwidth,
                                  uint32_t guardfraction_percentage);

bool vanguards_lite_is_enabled(void);
const routerset_t *get_layer2_guards(void);
void maintain_layer2_guards(void);
void purge_vanguards_lite(void);

#endif /* !defined(TOR_ENTRYNODES_H) */
