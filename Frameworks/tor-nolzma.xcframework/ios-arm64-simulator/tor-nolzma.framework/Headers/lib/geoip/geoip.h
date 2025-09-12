/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file geoip.h
 * \brief Header file for geoip.c.
 **/

#ifndef TOR_GEOIP_H
#define TOR_GEOIP_H

#include "orconfig.h"
#include "lib/net/nettypes.h"
#include "lib/testsupport/testsupport.h"
#include "lib/net/inaddr_st.h"
#include "lib/geoip/country.h"

#ifdef GEOIP_PRIVATE
STATIC int geoip_parse_entry(const char *line, sa_family_t family);
STATIC void clear_geoip_db(void);

STATIC int geoip_get_country_by_ipv4(uint32_t ipaddr);
STATIC int geoip_get_country_by_ipv6(const struct in6_addr *addr);
#endif /* defined(GEOIP_PRIVATE) */

struct in6_addr;
struct tor_addr_t;

/** A per-country GeoIP record. */
typedef struct geoip_country_t {
  /** A nul-terminated two-letter country-code. */
  char countrycode[3];
} geoip_country_t;

struct smartlist_t;
const struct smartlist_t *geoip_get_countries(void);

int geoip_load_file(sa_family_t family, const char *filename, int severity);
MOCK_DECL(int, geoip_get_country_by_addr, (const struct tor_addr_t *addr));
MOCK_DECL(int, geoip_get_n_countries, (void));
const char *geoip_get_country_name(country_t num);
MOCK_DECL(int, geoip_is_loaded, (sa_family_t family));
const char *geoip_db_digest(sa_family_t family);
MOCK_DECL(country_t, geoip_get_country, (const char *countrycode));

void geoip_free_all(void);

#endif /* !defined(TOR_GEOIP_H) */
