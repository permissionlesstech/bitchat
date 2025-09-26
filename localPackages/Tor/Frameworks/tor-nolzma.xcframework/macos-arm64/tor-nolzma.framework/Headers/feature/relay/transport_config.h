/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file transport_config.h
 * @brief Header for feature/relay/transport_config.c
 **/

#ifndef TOR_FEATURE_RELAY_TRANSPORT_CONFIG_H
#define TOR_FEATURE_RELAY_TRANSPORT_CONFIG_H

#ifdef HAVE_MODULE_RELAY

#include "lib/testsupport/testsupport.h"

struct or_options_t;
struct smartlist_t;

int options_validate_server_transport(const struct or_options_t *old_options,
                                      struct or_options_t *options,
                                      char **msg);

char *pt_get_bindaddr_from_config(const char *transport);
struct smartlist_t *pt_get_options_for_server_transport(const char *transport);

int options_act_server_transport(const struct or_options_t *old_options);

#ifdef RELAY_TRANSPORT_CONFIG_PRIVATE

STATIC struct smartlist_t *get_options_from_transport_options_line(
                      const char *line,
                      const char *transport);

#endif /* defined(RELAY_TRANSPORT_CONFIG_PRIVATE) */

#else /* !defined(HAVE_MODULE_RELAY) */

/** When tor is compiled with the relay module disabled, it can't be
 * configured with server pluggable transports.
 *
 * Returns -1 and sets msg to a newly allocated string, if ExtORPort,
 * ServerTransportPlugin, ServerTransportListenAddr, or
 * ServerTransportOptions are set in options. Otherwise returns 0. */
static inline int
options_validate_server_transport(const struct or_options_t *old_options,
                                  struct or_options_t *options,
                                  char **msg)
{
  (void)old_options;

  /* These ExtORPort checks are too strict, and will reject valid configs
   * that disable ports, like "ExtORPort 0". */
  if (options->ServerTransportPlugin ||
      options->ServerTransportListenAddr ||
      options->ServerTransportOptions ||
      options->ExtORPort_lines) {
    /* REJECT() this configuration */
    *msg = tor_strdup("This tor was built with relay mode disabled. "
                      "It can not be configured with an ExtORPort, "
                      "a ServerTransportPlugin, a ServerTransportListenAddr, "
                      "or ServerTransportOptions.");
    return -1;
  }

  return 0;
}

#define pt_get_bindaddr_from_config(transport) \
  (((void)(transport)),NULL)

/* 31851: called from client/transports.c, but only from server code */
#define pt_get_options_for_server_transport(transport) \
  (((void)(transport)),NULL)

#define options_validate_server_transport(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_act_server_transport(old_options) \
  (((void)(old_options)),0)

#endif /* defined(HAVE_MODULE_RELAY) */

#endif /* !defined(TOR_FEATURE_RELAY_TRANSPORT_CONFIG_H) */
