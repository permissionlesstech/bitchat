/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file ns_parse.h
 * \brief Header file for ns_parse.c.
 **/

#ifndef TOR_NS_PARSE_H
#define TOR_NS_PARSE_H

int router_get_networkstatus_v3_hashes(const char *s, size_t len,
                                       common_digests_t *digests);
int router_get_networkstatus_v3_signed_boundaries(const char *s, size_t len,
                                                  const char **start_out,
                                                  const char **end_out);
int router_get_networkstatus_v3_sha3_as_signed(uint8_t *digest_out,
                                               const char *s, size_t len);
int compare_vote_routerstatus_entries(const void **_a, const void **_b);

int networkstatus_verify_bw_weights(networkstatus_t *ns, int);
enum networkstatus_type_t;
networkstatus_t *networkstatus_parse_vote_from_string(const char *s,
                                           size_t len,
                                           const char **eos_out,
                                           enum networkstatus_type_t ns_type);

#ifdef NS_PARSE_PRIVATE
STATIC int routerstatus_parse_guardfraction(const char *guardfraction_str,
                                            networkstatus_t *vote,
                                            vote_routerstatus_t *vote_rs,
                                            routerstatus_t *rs);
struct memarea_t;
STATIC routerstatus_t *routerstatus_parse_entry_from_string(
                                     struct memarea_t *area,
                                     const char **s, const char *eos,
                                     smartlist_t *tokens,
                                     networkstatus_t *vote,
                                     vote_routerstatus_t *vote_rs,
                                     int consensus_method,
                                     consensus_flavor_t flav);
#endif /* defined(NS_PARSE_PRIVATE) */

#endif /* !defined(TOR_NS_PARSE_H) */
