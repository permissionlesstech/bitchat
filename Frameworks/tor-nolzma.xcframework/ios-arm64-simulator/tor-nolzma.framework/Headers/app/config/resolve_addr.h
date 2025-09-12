/* Copyright (c) 2020-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file resolve_addr.h
 * \brief Header file for resolve_addr.c.
 **/

#ifndef TOR_CONFIG_RESOLVE_ADDR_H
#define TOR_CONFIG_RESOLVE_ADDR_H

#include "app/config/config.h"
#include "core/mainloop/connection.h"

#include "app/config/or_options_st.h"

/** Method used to resolved an address. In other words, how was the address
 * discovered by tor. */
typedef enum {
  /* Default value. Indicate that no method found the address. */
  RESOLVED_ADDR_NONE              = 0,
  /* Found from the "Address" configuration option. */
  RESOLVED_ADDR_CONFIGURED        = 1,
  /* Found from the "ORPort" configuration option. */
  RESOLVED_ADDR_CONFIGURED_ORPORT = 2,
  /* Found by resolving the local hostname. */
  RESOLVED_ADDR_GETHOSTNAME       = 3,
  /* Found by querying the local interface(s). */
  RESOLVED_ADDR_INTERFACE         = 4,
  /* Found by resolving the hostname from the Address configuration option. */
  RESOLVED_ADDR_RESOLVED          = 5,
} resolved_addr_method_t;

const char *resolved_addr_method_to_str(const resolved_addr_method_t method);

#define get_orport_addr(family) \
  (portconf_get_first_advertised_addr(CONN_TYPE_OR_LISTENER, family))

bool find_my_address(const or_options_t *options, int family,
                     int warn_severity, tor_addr_t *addr_out,
                     resolved_addr_method_t *method_out, char **hostname_out);

void resolved_addr_get_last(int family, tor_addr_t *addr_out);
void resolved_addr_reset_last(int family);
void resolved_addr_set_last(const tor_addr_t *addr,
                            const resolved_addr_method_t method_used,
                            const char *hostname_used);

void resolved_addr_get_suggested(int family, tor_addr_t *addr_out);
void resolved_addr_set_suggested(const tor_addr_t *addr);

bool resolved_addr_is_configured(int family);

MOCK_DECL(bool, is_local_to_resolve_addr, (const tor_addr_t *addr));

#ifdef RESOLVE_ADDR_PRIVATE

#ifdef TOR_UNIT_TESTS

void resolve_addr_reset_suggested(int family);

#endif /* TOR_UNIT_TESTS */

#endif /* defined(RESOLVE_ADDR_PRIVATE) */

#endif /* !defined(TOR_CONFIG_RESOLVE_ADDR_H) */

