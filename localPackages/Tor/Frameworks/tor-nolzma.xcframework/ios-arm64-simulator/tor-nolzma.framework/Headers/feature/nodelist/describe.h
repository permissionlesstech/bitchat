/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file describe.h
 * \brief Header file for describe.c.
 **/

#ifndef TOR_DESCRIBE_H
#define TOR_DESCRIBE_H

struct extend_info_t;
struct node_t;
struct routerinfo_t;
struct routerstatus_t;

const char *extend_info_describe(const struct extend_info_t *ei);
const char *node_describe(const struct node_t *node);
const char *router_describe(const struct routerinfo_t *ri);
const char *routerstatus_describe(const struct routerstatus_t *ri);

void router_get_verbose_nickname(char *buf, const routerinfo_t *router);

#if defined(DESCRIBE_PRIVATE) || defined(TOR_UNIT_TESTS)

/**
 * Longest allowed output for an IPv4 address "255.255.255.255", with NO
 * terminating NUL.
 */
#define IPV4_BUF_LEN_NO_NUL 15

/**
 * Longest allowed output of format_node_description, plus 1 character for
 * NUL.  This allows space for:
 * "$FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF~xxxxxxxxxxxxxxxxxxx "
 * "[+++++++++++++++++++++++++++++++++++++++++++] at"
 * " 255.255.255.255 and [ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255]"
 * plus a terminating NUL.
 */
#define NODE_DESC_BUF_LEN \
  (MAX_VERBOSE_NICKNAME_LEN+4 \
   + ED25519_BASE64_LEN+3 \
   + IPV4_BUF_LEN_NO_NUL+5 \
   + TOR_ADDR_BUF_LEN)

#endif /* defined(DESCRIBE_PRIVATE) || defined(TOR_UNIT_TESTS) */

#ifdef TOR_UNIT_TESTS
struct ed25519_public_key_t;

STATIC const char *format_node_description(char *buf,
                              const char *rsa_id_digest,
                              const struct ed25519_public_key_t *ed25519_id,
                              const char *nickname,
                              const tor_addr_t *ipv4_addr,
                              const tor_addr_t *ipv6_addr);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TOR_DESCRIBE_H) */
