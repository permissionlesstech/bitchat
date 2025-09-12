/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file policy_parse.h
 * \brief Header file for policy_parse.c.
 **/

#ifndef TOR_POLICY_PARSE_H
#define TOR_POLICY_PARSE_H

#include "lib/testsupport/testsupport.h"

struct directory_token_t;

MOCK_DECL(addr_policy_t *, router_parse_addr_policy_item_from_string,
         (const char *s, int assume_action, int *malformed_list));

addr_policy_t *router_parse_addr_policy(struct directory_token_t *tok,
                                        unsigned fmt_flags);

#endif /* !defined(TOR_POLICY_PARSE_H) */
