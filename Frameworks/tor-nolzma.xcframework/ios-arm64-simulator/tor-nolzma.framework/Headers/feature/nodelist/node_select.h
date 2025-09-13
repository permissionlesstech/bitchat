/* Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file node_select.h
 * \brief Header file for node_select.c
 **/

#ifndef TOR_NODE_SELECT_H
#define TOR_NODE_SELECT_H

/** Flags to be passed to control router_choose_random_node() to indicate what
 * kind of nodes to pick according to what algorithm. */
typedef enum router_crn_flags_t {
  /* Try to choose stable nodes. */
  CRN_NEED_UPTIME = 1<<0,
  /* Try to choose nodes with a reasonable amount of bandwidth. */
  CRN_NEED_CAPACITY = 1<<1,
  /* Only choose nodes if we have downloaded their descriptor or
   * microdescriptor. */
  CRN_NEED_DESC = 1<<2,
  /* Choose nodes that can be used as Guard relays. */
  CRN_NEED_GUARD = 1<<3,
  /* On clients, only provide nodes that we can connect to directly, based on
   * our firewall rules. */
  CRN_DIRECT_CONN = 1<<4,
  /* On clients, if choosing a node for a direct connection, only provide
   * nodes that satisfy ClientPreferIPv6OR. */
  CRN_PREF_ADDR = 1<<5,
  /* On clients, indicate that we need a HS related circuit (IP, HSDir, or RP).
   * This is used in order to avoid certain nodes for these purposes. */
  CRN_FOR_HS = 1<<6,
  /* On clients, only provide nodes that can initiate IPv6 extends. */
  CRN_INITIATE_IPV6_EXTEND = 1<<7,
  /* On clients, only provide nodes that support Conflux (Relay=5). */
  CRN_CONFLUX = 1<<8,
} router_crn_flags_t;

/** Possible ways to weight routers when choosing one randomly.  See
 * routerlist_sl_choose_by_bandwidth() for more information.*/
typedef enum bandwidth_weight_rule_t {
  NO_WEIGHTING, WEIGHT_FOR_EXIT, WEIGHT_FOR_MID, WEIGHT_FOR_GUARD,
  WEIGHT_FOR_DIR
} bandwidth_weight_rule_t;

/* Flags for pick_directory_server() and pick_trusteddirserver(). */
/** Flag to indicate that we should not automatically be willing to use
 * ourself to answer a directory request.
 * Passed to router_pick_directory_server (et al).*/
#define PDS_ALLOW_SELF                 (1<<0)
/** Flag to indicate that if no servers seem to be up, we should mark all
 * directory servers as up and try again.
 * Passed to router_pick_directory_server (et al).*/
#define PDS_RETRY_IF_NO_SERVERS        (1<<1)
/** Flag to indicate that we should not exclude directory servers that
 * our ReachableAddress settings would exclude.  This usually means that
 * we're going to connect to the server over Tor, and so we don't need to
 * worry about our firewall telling us we can't.
 * Passed to router_pick_directory_server (et al).*/
#define PDS_IGNORE_FASCISTFIREWALL     (1<<2)
/** Flag to indicate that we should not use any directory authority to which
 * we have an existing directory connection for downloading server descriptors
 * or extrainfo documents.
 *
 * Passed to router_pick_directory_server (et al)
 */
#define PDS_NO_EXISTING_SERVERDESC_FETCH (1<<3)
/** Flag to indicate that we should not use any directory authority to which
 * we have an existing directory connection for downloading microdescs.
 *
 * Passed to router_pick_directory_server (et al)
 */
#define PDS_NO_EXISTING_MICRODESC_FETCH (1<<4)

const routerstatus_t *router_pick_directory_server(dirinfo_type_t type,
                                                   int flags);

int router_get_my_share_of_directory_requests(double *v3_share_out);

const node_t *node_sl_choose_by_bandwidth(const smartlist_t *sl,
                                          bandwidth_weight_rule_t rule);
double frac_nodes_with_descriptors(const smartlist_t *sl,
                                   bandwidth_weight_rule_t rule,
                                   int for_direct_conn);
const node_t *router_choose_random_node(smartlist_t *excludedsmartlist,
                                        struct routerset_t *excludedset,
                                        router_crn_flags_t flags);

const routerstatus_t *router_pick_trusteddirserver(dirinfo_type_t type,
                                                   int flags);
const routerstatus_t *router_pick_fallback_dirserver(dirinfo_type_t type,
                                                     int flags);

#ifdef NODE_SELECT_PRIVATE
STATIC int choose_array_element_by_weight(const uint64_t *entries,
                                          int n_entries);
STATIC void scale_array_elements_to_u64(uint64_t *entries_out,
                                        const double *entries_in,
                                        int n_entries,
                                        uint64_t *total_out);
STATIC const routerstatus_t *router_pick_directory_server_impl(
                                           dirinfo_type_t auth, int flags,
                                           int *n_busy_out);
STATIC int router_is_already_dir_fetching(const tor_addr_port_t *ap,
                                          int serverdesc, int microdesc);
#endif /* defined(NODE_SELECT_PRIVATE) */

#endif /* !defined(TOR_NODE_SELECT_H) */
