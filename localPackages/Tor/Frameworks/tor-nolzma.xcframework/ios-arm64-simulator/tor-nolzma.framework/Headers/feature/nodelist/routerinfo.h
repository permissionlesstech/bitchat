/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file routerinfo.h
 * \brief Header file for routerinfo.c.
 **/

#ifndef TOR_ROUTERINFO_H
#define TOR_ROUTERINFO_H

int router_get_orport(const routerinfo_t *router,
                       tor_addr_port_t *addr_port_out,
                       int family);
int router_has_orport(const routerinfo_t *router,
                      const tor_addr_port_t *orport);

struct ed25519_public_key_t;
const struct ed25519_public_key_t *routerinfo_get_ed25519_id(
                      const routerinfo_t *ri);

smartlist_t *router_get_all_orports(const routerinfo_t *ri);

const char *router_purpose_to_string(uint8_t p);
uint8_t router_purpose_from_string(const char *s);

#endif /* !defined(TOR_ROUTERINFO_H) */
