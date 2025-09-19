/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file routerparse.h
 * \brief Header file for routerparse.c.
 **/

#ifndef TOR_ROUTERPARSE_H
#define TOR_ROUTERPARSE_H

int router_get_router_hash(const char *s, size_t s_len, char *digest);
int router_get_extrainfo_hash(const char *s, size_t s_len, char *digest);

int router_parse_list_from_string(const char **s, const char *eos,
                                  smartlist_t *dest,
                                  saved_location_t saved_location,
                                  int is_extrainfo,
                                  int allow_annotations,
                                  const char *prepend_annotations,
                                  smartlist_t *invalid_digests_out);

routerinfo_t *router_parse_entry_from_string(const char *s, const char *end,
                                             int cache_copy,
                                             int allow_annotations,
                                             const char *prepend_annotations,
                                             int *can_dl_again_out);
struct digest_ri_map_t;
extrainfo_t *extrainfo_parse_entry_from_string(const char *s, const char *end,
                             int cache_copy, struct digest_ri_map_t *routermap,
                             int *can_dl_again_out);

int find_single_ipv6_orport(const smartlist_t *list,
                            tor_addr_t *addr_out,
                            uint16_t *port_out);

void routerparse_init(void);
void routerparse_free_all(void);

#ifdef ROUTERDESC_TOKEN_TABLE_PRIVATE
#include "feature/dirparse/parsecommon.h"
extern const struct token_rule_t routerdesc_token_table[];
#endif

#define ED_DESC_SIGNATURE_PREFIX "Tor router descriptor signature v1"

#endif /* !defined(TOR_ROUTERPARSE_H) */
