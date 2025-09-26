/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file nodelist.h
 * \brief Header file for nodelist.c.
 **/

#ifndef TOR_NODELIST_H
#define TOR_NODELIST_H

struct ed25519_public_key_t;
struct curve25519_public_key_t;

#define node_assert_ok(n) STMT_BEGIN {                          \
    tor_assert((n)->ri || (n)->rs);                             \
  } STMT_END

MOCK_DECL(node_t *, node_get_mutable_by_id,(const char *identity_digest));
MOCK_DECL(const node_t *, node_get_by_id, (const char *identity_digest));
node_t *node_get_mutable_by_ed25519_id(
                            const struct ed25519_public_key_t *ed_id);
MOCK_DECL(const node_t *, node_get_by_ed25519_id,
          (const struct ed25519_public_key_t *ed_id));

#define NNF_NO_WARN_UNNAMED (1u<<0)

const node_t *node_get_by_hex_id(const char *identity_digest,
                                 unsigned flags);
node_t *nodelist_set_routerinfo(routerinfo_t *ri, routerinfo_t **ri_old_out);
node_t *nodelist_add_microdesc(microdesc_t *md);
void nodelist_set_consensus(const networkstatus_t *ns);
void nodelist_ensure_freshness(const networkstatus_t *ns);
int nodelist_probably_contains_address(const tor_addr_t *addr);
bool nodelist_reentry_contains(const tor_addr_t *addr, uint16_t port);
void nodelist_add_addr_to_address_set(const tor_addr_t *addr,
                                      uint16_t or_port, uint16_t dir_port);

void nodelist_remove_microdesc(const char *identity_digest, microdesc_t *md);
void nodelist_remove_routerinfo(routerinfo_t *ri);
void nodelist_purge(void);
smartlist_t *nodelist_find_nodes_with_microdesc(const microdesc_t *md);

void nodelist_free_all(void);
void nodelist_assert_ok(void);

MOCK_DECL(const node_t *, node_get_by_nickname,
          (const char *nickname, unsigned flags));
void node_get_verbose_nickname(const node_t *node,
                               char *verbose_name_out);
void node_get_verbose_nickname_by_id(const char *id_digest,
                                char *verbose_name_out);
int node_is_dir(const node_t *node);
int node_is_good_exit(const node_t *node);
int node_has_any_descriptor(const node_t *node);
int node_has_preferred_descriptor(const node_t *node,
                                  int for_direct_connect);
int node_get_purpose(const node_t *node);
#define node_is_bridge(node) \
  (node_get_purpose((node)) == ROUTER_PURPOSE_BRIDGE)
int node_is_me(const node_t *node);
int node_exit_policy_rejects_all(const node_t *node);
int node_exit_policy_is_exact(const node_t *node, sa_family_t family);
smartlist_t *node_get_all_orports(const node_t *node);
int node_allows_single_hop_exits(const node_t *node);
const char *node_get_nickname(const node_t *node);
const char *node_get_platform(const node_t *node);
void node_get_address_string(const node_t *node, char *cp, size_t len);
long node_get_declared_uptime(const node_t *node);
MOCK_DECL(const struct ed25519_public_key_t *,node_get_ed25519_id,
          (const node_t *node));
int node_ed25519_id_matches(const node_t *node,
                            const struct ed25519_public_key_t *id);
MOCK_DECL(bool,node_supports_ed25519_link_authentication,
          (const node_t *node,
           bool compatible_with_us));
bool node_supports_v3_hsdir(const node_t *node);
bool node_supports_ed25519_hs_intro(const node_t *node);
bool node_supports_v3_rendezvous_point(const node_t *node);
bool node_supports_establish_intro_dos_extension(const node_t *node);
bool node_supports_initiating_ipv6_extends(const node_t *node);
bool node_supports_accepting_ipv6_extends(const node_t *node,
                                          bool need_canonical_ipv6_conn);
bool node_supports_conflux(const node_t *node);

const uint8_t *node_get_rsa_id_digest(const node_t *node);
MOCK_DECL(smartlist_t *,node_get_link_specifier_smartlist,(const node_t *node,
                                                           bool direct_conn));
void link_specifier_smartlist_free_(smartlist_t *ls_list);
#define link_specifier_smartlist_free(ls_list) \
  FREE_AND_NULL(smartlist_t, link_specifier_smartlist_free_, (ls_list))

int node_has_ipv6_addr(const node_t *node);
int node_has_ipv6_orport(const node_t *node);
int node_has_ipv6_dirport(const node_t *node);
/* Deprecated - use node_ipv6_or_preferred or node_ipv6_dir_preferred */
#define node_ipv6_preferred(node) node_ipv6_or_preferred(node)
int node_ipv6_or_preferred(const node_t *node);
void node_get_prim_orport(const node_t *node, tor_addr_port_t *ap_out);
void node_get_pref_orport(const node_t *node, tor_addr_port_t *ap_out);
void node_get_pref_ipv6_orport(const node_t *node, tor_addr_port_t *ap_out);
int node_ipv6_dir_preferred(const node_t *node);
void node_get_prim_dirport(const node_t *node, tor_addr_port_t *ap_out);
void node_get_pref_dirport(const node_t *node, tor_addr_port_t *ap_out);
void node_get_pref_ipv6_dirport(const node_t *node, tor_addr_port_t *ap_out);
int node_has_curve25519_onion_key(const node_t *node);
const struct curve25519_public_key_t *node_get_curve25519_onion_key(
                                  const node_t *node);
crypto_pk_t *node_get_rsa_onion_key(const node_t *node);

MOCK_DECL(const smartlist_t *, nodelist_get_list, (void));

/* Temporary during transition to multiple addresses.  */
void node_get_addr(const node_t *node, tor_addr_t *addr_out);

void nodelist_refresh_countries(void);
void node_set_country(node_t *node);
void nodelist_add_node_and_family(smartlist_t *nodes, const node_t *node);
int nodes_in_same_family(const node_t *node1, const node_t *node2);

const node_t *router_find_exact_exit_enclave(const char *address,
                                             uint16_t port);
int node_is_unreliable(const node_t *router, int need_uptime,
                         int need_capacity, int need_guard);
int router_exit_policy_all_nodes_reject(const tor_addr_t *addr, uint16_t port,
                                        int need_uptime);
void router_set_status(const char *digest, int up);
int router_addrs_in_same_network(const tor_addr_t *a1,
                                 const tor_addr_t *a2);

/** router_have_minimum_dir_info tests to see if we have enough
 * descriptor information to create circuits.
 * If there are exits in the consensus, we wait until we have enough
 * info to create exit paths before creating any circuits. If there are
 * no exits in the consensus, we wait for enough info to create internal
 * paths, and should avoid creating exit paths, as they will simply fail.
 * We make sure we create all available circuit types at the same time. */
MOCK_DECL(int, router_have_minimum_dir_info,(void));

/** Set to CONSENSUS_PATH_EXIT if there is at least one exit node
 * in the consensus. We update this flag in compute_frac_paths_available if
 * there is at least one relay that has an Exit flag in the consensus.
 * Used to avoid building exit circuits when they will almost certainly fail.
 * Set to CONSENSUS_PATH_INTERNAL if there are no exits in the consensus.
 * (This situation typically occurs during bootstrap of a test network.)
 * Set to CONSENSUS_PATH_UNKNOWN if we have never checked, or have
 * reason to believe our last known value was invalid or has expired.
 */
typedef enum {
  /* we haven't checked yet, or we have invalidated our previous check */
  CONSENSUS_PATH_UNKNOWN = -1,
  /* The consensus only has internal relays, and we should only
   * create internal paths, circuits, streams, ... */
  CONSENSUS_PATH_INTERNAL = 0,
  /* The consensus has at least one exit, and can therefore (potentially)
   * create exit and internal paths, circuits, streams, ... */
  CONSENSUS_PATH_EXIT = 1
} consensus_path_type_t;

MOCK_DECL(consensus_path_type_t, router_have_consensus_path, (void));

void router_dir_info_changed(void);
const char *get_dir_info_status_string(void);
int count_loading_descriptors_progress(void);

#ifdef NODELIST_PRIVATE

STATIC int node_nickname_matches(const node_t *node, const char *nickname);
STATIC int node_in_nickname_smartlist(const smartlist_t *lst,
                                      const node_t *node);
STATIC int node_family_contains(const node_t *n1, const node_t *n2);
STATIC bool node_has_declared_family(const node_t *node);
STATIC void node_lookup_declared_family(smartlist_t *out, const node_t *node);

#ifdef TOR_UNIT_TESTS

STATIC void node_set_hsdir_index(node_t *node, const networkstatus_t *ns);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(NODELIST_PRIVATE) */

MOCK_DECL(int, get_estimated_address_per_node, (void));

#endif /* !defined(TOR_NODELIST_H) */
