/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file policies.h
 * \brief Header file for policies.c.
 **/

#ifndef TOR_POLICIES_H
#define TOR_POLICIES_H

/* (length of
 * "accept6 [ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]/128:65535-65535\n"
 * plus a terminating NUL, rounded up to a nice number.)
 */
#define POLICY_BUF_LEN 72

#define EXIT_POLICY_IPV6_ENABLED             (1 << 0)
#define EXIT_POLICY_REJECT_PRIVATE           (1 << 1)
#define EXIT_POLICY_ADD_DEFAULT              (1 << 2)
#define EXIT_POLICY_REJECT_LOCAL_INTERFACES  (1 << 3)
#define EXIT_POLICY_ADD_REDUCED              (1 << 4)
#define EXIT_POLICY_OPTION_MAX             EXIT_POLICY_ADD_REDUCED
/* All options set: used for unit testing */
#define EXIT_POLICY_OPTION_ALL             ((EXIT_POLICY_OPTION_MAX << 1) - 1)

typedef enum firewall_connection_t {
  FIREWALL_OR_CONNECTION      = 0,
  FIREWALL_DIR_CONNECTION     = 1
} firewall_connection_t;

typedef int exit_policy_parser_cfg_t;

/** Outcome of applying an address policy to an address. */
typedef enum {
  /** The address was accepted */
  ADDR_POLICY_ACCEPTED=0,
  /** The address was rejected */
  ADDR_POLICY_REJECTED=-1,
  /** Part of the address was unknown, but as far as we can tell, it was
   * accepted. */
  ADDR_POLICY_PROBABLY_ACCEPTED=1,
  /** Part of the address was unknown, but as far as we can tell, it was
   * rejected. */
  ADDR_POLICY_PROBABLY_REJECTED=2,
} addr_policy_result_t;

/** A single entry in a parsed policy summary, describing a range of ports. */
typedef struct short_policy_entry_t {
  uint16_t min_port, max_port;
} short_policy_entry_t;

/** A short_poliy_t is the parsed version of a policy summary. */
typedef struct short_policy_t {
  /** True if the members of 'entries' are port ranges to accept; false if
   * they are port ranges to reject */
  unsigned int is_accept : 1;
  /** The actual number of values in 'entries'. */
  unsigned int n_entries : 31;
  /** An array of 0 or more short_policy_entry_t values, each describing a
   * range of ports that this policy accepts or rejects (depending on the
   * value of is_accept).
   */
  short_policy_entry_t entries[FLEXIBLE_ARRAY_MEMBER];
} short_policy_t;

int firewall_is_fascist_or(void);
int firewall_is_fascist_dir(void);
int reachable_addr_use_ipv6(const or_options_t *options);
int reachable_addr_prefer_ipv6_orport(const or_options_t *options);
int reachable_addr_prefer_ipv6_dirport(const or_options_t *options);

int reachable_addr_allows_addr(const tor_addr_t *addr,
                                         uint16_t port,
                                         firewall_connection_t fw_connection,
                                         int pref_only, int pref_ipv6);

int reachable_addr_allows_rs(const routerstatus_t *rs,
                               firewall_connection_t fw_connection,
                               int pref_only);
int reachable_addr_allows_node(const node_t *node,
                                 firewall_connection_t fw_connection,
                                 int pref_only);
int reachable_addr_allows_dir_server(const dir_server_t *ds,
                                       firewall_connection_t fw_connection,
                                       int pref_only);

void reachable_addr_choose_from_rs(const routerstatus_t *rs,
                                        firewall_connection_t fw_connection,
                                        int pref_only, tor_addr_port_t* ap);
void reachable_addr_choose_from_ls(const smartlist_t *lspecs,
                                        int pref_only, tor_addr_port_t* ap);
void reachable_addr_choose_from_node(const node_t *node,
                                          firewall_connection_t fw_connection,
                                          int pref_only, tor_addr_port_t* ap);
void reachable_addr_choose_from_dir_server(const dir_server_t *ds,
                                          firewall_connection_t fw_connection,
                                          int pref_only, tor_addr_port_t* ap);

int dir_policy_permits_address(const tor_addr_t *addr);
int socks_policy_permits_address(const tor_addr_t *addr);
int metrics_policy_permits_address(const tor_addr_t *addr);
int authdir_policy_permits_address(const tor_addr_t *addr, uint16_t port);
int authdir_policy_valid_address(const tor_addr_t *addr, uint16_t port);
int authdir_policy_badexit_address(const tor_addr_t *addr, uint16_t port);
int authdir_policy_middleonly_address(const tor_addr_t *addr, uint16_t port);

int policy_using_default_exit_options(const or_options_t *or_options);
int validate_addr_policies(const or_options_t *options, char **msg);
void policy_expand_private(smartlist_t **policy);
void policy_expand_unspec(smartlist_t **policy);
int policies_parse_from_options(const or_options_t *options);

addr_policy_t *addr_policy_get_canonical_entry(addr_policy_t *ent);
int addr_policies_eq(const smartlist_t *a, const smartlist_t *b);
MOCK_DECL(addr_policy_result_t, compare_tor_addr_to_addr_policy,
    (const tor_addr_t *addr, uint16_t port, const smartlist_t *policy));
addr_policy_result_t compare_tor_addr_to_node_policy(const tor_addr_t *addr,
                              uint16_t port, const node_t *node);

int policies_parse_exit_policy_from_options(
                                          const or_options_t *or_options,
                                          const tor_addr_t *ipv4_local_address,
                                          const tor_addr_t *ipv6_local_address,
                                          smartlist_t **result);
struct config_line_t;
int policies_parse_exit_policy(struct config_line_t *cfg, smartlist_t **dest,
                               exit_policy_parser_cfg_t options,
                               const smartlist_t *configured_addresses);
void policies_parse_exit_policy_reject_private(
                                      smartlist_t **dest,
                                      int ipv6_exit,
                                      const smartlist_t *configured_addresses,
                                      int reject_interface_addresses,
                                      int reject_configured_port_addresses);
void policies_exit_policy_append_reject_star(smartlist_t **dest);
void addr_policy_append_reject_addr(smartlist_t **dest,
                                    const tor_addr_t *addr);
void addr_policy_append_reject_addr_list(smartlist_t **dest,
                                         const smartlist_t *addrs);
void policies_set_node_exitpolicy_to_reject_all(node_t *exitrouter);
int exit_policy_is_general_exit(smartlist_t *policy);
int policy_is_reject_star(const smartlist_t *policy, sa_family_t family,
                          int reject_by_default);
char * policy_dump_to_string(const smartlist_t *policy_list,
                             int include_ipv4,
                             int include_ipv6);
int getinfo_helper_policies(control_connection_t *conn,
                            const char *question, char **answer,
                            const char **errmsg);
int policy_write_item(char *buf, size_t buflen, const addr_policy_t *item,
                      int format_for_desc);

void addr_policy_list_free_(smartlist_t *p);
#define addr_policy_list_free(lst) \
  FREE_AND_NULL(smartlist_t, addr_policy_list_free_, (lst))
void addr_policy_free_(addr_policy_t *p);
#define addr_policy_free(p) \
  FREE_AND_NULL(addr_policy_t, addr_policy_free_, (p))
void policies_free_all(void);

char *policy_summarize(smartlist_t *policy, sa_family_t family);

short_policy_t *parse_short_policy(const char *summary);
char *write_short_policy(const short_policy_t *policy);
void short_policy_free_(short_policy_t *policy);
#define short_policy_free(p) \
  FREE_AND_NULL(short_policy_t, short_policy_free_, (p))
int short_policy_is_reject_star(const short_policy_t *policy);
addr_policy_result_t compare_tor_addr_to_short_policy(
                          const tor_addr_t *addr, uint16_t port,
                          const short_policy_t *policy);

#ifdef POLICIES_PRIVATE
STATIC void append_exit_policy_string(smartlist_t **policy, const char *more);
STATIC int reachable_addr_allows(const tor_addr_t *addr,
                                           uint16_t port,
                                           smartlist_t *firewall_policy,
                                           int pref_only, int pref_ipv6);
STATIC const tor_addr_port_t * reachable_addr_choose(
                                          const tor_addr_port_t *a,
                                          const tor_addr_port_t *b,
                                          int want_a,
                                          firewall_connection_t fw_connection,
                                          int pref_only, int pref_ipv6);

#endif /* defined(POLICIES_PRIVATE) */

#endif /* !defined(TOR_POLICIES_H) */
