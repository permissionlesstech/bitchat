/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file router.h
 * \brief Header file for router.c.
 **/

#ifndef TOR_ROUTER_H
#define TOR_ROUTER_H

#include "lib/testsupport/testsupport.h"

struct curve25519_keypair_t;
struct ed25519_keypair_t;

#define TOR_ROUTERINFO_ERROR_NO_EXT_ADDR     (-1)
#define TOR_ROUTERINFO_ERROR_CANNOT_PARSE    (-2)
#define TOR_ROUTERINFO_ERROR_NOT_A_SERVER    (-3)
#define TOR_ROUTERINFO_ERROR_DIGEST_FAILED   (-4)
#define TOR_ROUTERINFO_ERROR_CANNOT_GENERATE (-5)
#define TOR_ROUTERINFO_ERROR_DESC_REBUILDING (-6)
#define TOR_ROUTERINFO_ERROR_INTERNAL_BUG    (-7)

MOCK_DECL(crypto_pk_t *,get_onion_key,(void));
time_t get_onion_key_set_at(void);
void set_server_identity_key(crypto_pk_t *k);
/* Some compilers are clever enough to know that when relay mode is disabled,
 * this function never returns. */
#ifdef HAVE_MODULE_RELAY
MOCK_DECL(crypto_pk_t *,get_server_identity_key,(void));
#else
#define get_server_identity_key() (tor_abort_(),NULL)
#endif
int server_identity_key_is_set(void);
void set_client_identity_key(crypto_pk_t *k);
crypto_pk_t *get_tlsclient_identity_key(void);
int client_identity_key_is_set(void);
MOCK_DECL(authority_cert_t *, get_my_v3_authority_cert, (void));
crypto_pk_t *get_my_v3_authority_signing_key(void);
authority_cert_t *get_my_v3_legacy_cert(void);
crypto_pk_t *get_my_v3_legacy_signing_key(void);
void dup_onion_keys(crypto_pk_t **key, crypto_pk_t **last);
void expire_old_onion_keys(void);
bool rotate_onion_key(void);
void v3_authority_check_key_expiry(void);
int get_onion_key_lifetime(void);
int get_onion_key_grace_period(void);

crypto_pk_t *router_get_rsa_onion_pkey(const char *pkey, size_t pkey_len);
void router_set_rsa_onion_pkey(const crypto_pk_t *pk, char **onion_pkey_out,
                               size_t *onion_pkey_len);

di_digest256_map_t *construct_ntor_key_map(void);
void ntor_key_map_free_(di_digest256_map_t *map);
#define ntor_key_map_free(map) \
  FREE_AND_NULL(di_digest256_map_t, ntor_key_map_free_, (map))

int router_initialize_tls_context(void);
int init_keys(void);
int init_keys_client(void);

uint16_t router_get_active_listener_port_by_type_af(int listener_type,
                                                    sa_family_t family);
void routerconf_find_ipv6_or_ap(const or_options_t *options,
                                      tor_addr_port_t *ipv6_ap_out);
bool routerconf_has_ipv6_orport(const or_options_t *options);
MOCK_DECL(bool, router_can_extend_over_ipv6,(const or_options_t *options));
uint16_t routerconf_find_or_port(const or_options_t *options,
                                       sa_family_t family);
uint16_t routerconf_find_dir_port(const or_options_t *options,
                                        uint16_t dirport);

int router_should_advertise_dirport(const or_options_t *options,
                                    uint16_t dir_port);

void consider_publishable_server(int force);
int should_refuse_unknown_exits(const or_options_t *options);

void router_new_consensus_params(const networkstatus_t *);
void router_upload_dir_desc_to_dirservers(int force);
void mark_my_descriptor_dirty_if_too_old(time_t now);
void mark_my_descriptor_dirty(const char *reason);
void mark_my_descriptor_if_omit_ipv6_changes(const char *reason,
                                               bool omit_ipv6);
void check_descriptor_bandwidth_changed(time_t now);
void check_descriptor_ipaddress_changed(time_t now);
int router_has_bandwidth_to_be_dirserver(const or_options_t *options);
int router_compare_to_my_exit_policy(const tor_addr_t *addr, uint16_t port);
MOCK_DECL(int, router_my_exit_policy_is_reject_star,(void));
MOCK_DECL(const routerinfo_t *, router_get_my_routerinfo, (void));
MOCK_DECL(const routerinfo_t *, router_get_my_routerinfo_with_err,(int *err));
extrainfo_t *router_get_my_extrainfo(void);
const char *router_get_my_descriptor(void);
const char *router_get_descriptor_gen_reason(void);
int router_digest_is_me(const char *digest);
const uint8_t *router_get_my_id_digest(void);
int router_extrainfo_digest_is_me(const char *digest);
int router_is_me(const routerinfo_t *router);
bool router_addr_is_my_published_addr(const tor_addr_t *addr);
int router_build_fresh_descriptor(routerinfo_t **r, extrainfo_t **e);
bool router_rebuild_descriptor(int force);
char *router_dump_router_to_string(routerinfo_t *router,
                             const crypto_pk_t *ident_key,
                             const crypto_pk_t *tap_key,
                             const struct curve25519_keypair_t *ntor_keypair,
                             const struct ed25519_keypair_t *signing_keypair);
char *router_dump_exit_policy_to_string(const routerinfo_t *router,
                                         int include_ipv4,
                                         int include_ipv6);
int extrainfo_dump_to_string(char **s, extrainfo_t *extrainfo,
                             crypto_pk_t *ident_key,
                             const struct ed25519_keypair_t *signing_keypair);

const char *routerinfo_err_to_string(int err);
int routerinfo_err_is_transient(int err);

void log_addr_has_changed(int severity, const tor_addr_t *prev,
                          const tor_addr_t *cur, const char *source);

void router_reset_warnings(void);
void router_free_all(void);

#ifdef ROUTER_PRIVATE
/* Used only by router.c and the unit tests */
STATIC void get_platform_str(char *platform, size_t len);
STATIC int router_write_fingerprint(int hashed, int ed25519_identity);
STATIC smartlist_t *get_my_declared_family(const or_options_t *options);
STATIC void router_announce_bridge_status_page(void);
STATIC int load_stats_file(const char *filename, const char *ts_tag,
                           time_t now, char **out);

#ifdef TOR_UNIT_TESTS
extern time_t desc_clean_since;
extern const char *desc_dirty_reason;
void set_server_identity_key_digest_testing(const uint8_t *digest);
MOCK_DECL(STATIC const struct curve25519_keypair_t *,
                                       get_current_curve25519_keypair,(void));

MOCK_DECL(STATIC int,
              router_build_fresh_unsigned_routerinfo,(routerinfo_t **ri_out));
STATIC extrainfo_t *router_build_fresh_signed_extrainfo(
                                                      const routerinfo_t *ri);
STATIC void router_update_routerinfo_from_extrainfo(routerinfo_t *ri,
                                                    const extrainfo_t *ei);
STATIC int router_dump_and_sign_routerinfo_descriptor_body(routerinfo_t *ri);
#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(ROUTER_PRIVATE) */

#endif /* !defined(TOR_ROUTER_H) */
