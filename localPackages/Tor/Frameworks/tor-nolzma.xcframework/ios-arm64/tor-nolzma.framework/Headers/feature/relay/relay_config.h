/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file relay_config.h
 * @brief Header for feature/relay/relay_config.c
 **/

#ifndef TOR_FEATURE_RELAY_RELAY_CONFIG_H
#define TOR_FEATURE_RELAY_RELAY_CONFIG_H

struct or_options_t;

#ifdef HAVE_MODULE_RELAY

#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"

struct smartlist_t;

int options_validate_relay_mode(const struct or_options_t *old_options,
                                struct or_options_t *options,
                                char **msg);

MOCK_DECL(const char*, relay_get_dirportfrontpage, (void));
void relay_config_free_all(void);

uint32_t relay_get_effective_bwrate(const struct or_options_t *options);
uint32_t relay_get_effective_bwburst(const struct or_options_t *options);

void port_warn_nonlocal_ext_orports(const struct smartlist_t *ports,
                               const char *portname);

int port_parse_ports_relay(struct or_options_t *options,
                      char **msg,
                      struct smartlist_t *ports_out,
                      int *have_low_ports_out);
void port_update_port_set_relay(struct or_options_t *options,
                           const struct smartlist_t *ports);

int options_validate_relay_os(const struct or_options_t *old_options,
                              struct or_options_t *options,
                              char **msg);

int options_validate_relay_info(const struct or_options_t *old_options,
                                struct or_options_t *options,
                                char **msg);

int options_validate_publish_server(const struct or_options_t *old_options,
                                    struct or_options_t *options,
                                    char **msg);

int options_validate_relay_padding(const struct or_options_t *old_options,
                                   struct or_options_t *options,
                                   char **msg);

int options_validate_relay_bandwidth(const struct or_options_t *old_options,
                                     struct or_options_t *options,
                                     char **msg);

int options_validate_relay_accounting(const struct or_options_t *old_options,
                                      struct or_options_t *options,
                                      char **msg);

int options_validate_relay_testing(const struct or_options_t *old_options,
                                   struct or_options_t *options,
                                   char **msg);

int options_act_relay(const struct or_options_t *old_options);
int options_act_relay_accounting(const struct or_options_t *old_options);
int options_act_relay_bandwidth(const struct or_options_t *old_options);
int options_act_bridge_stats(const struct or_options_t *old_options);

int options_act_relay_stats(const struct or_options_t *old_options,
                            bool *print_notice_out);
void options_act_relay_stats_msg(void);

int options_act_relay_desc(const struct or_options_t *old_options);
int options_act_relay_dos(const struct or_options_t *old_options);
int options_act_relay_dir(const struct or_options_t *old_options);

#ifdef RELAY_CONFIG_PRIVATE

STATIC void remove_duplicate_orports(struct smartlist_t *ports);
STATIC int check_bridge_distribution_setting(const char *bd);
STATIC int have_enough_mem_for_dircache(const struct or_options_t *options,
                                        size_t total_mem, char **msg);
#ifdef TOR_UNIT_TESTS

struct port_cfg_t;
STATIC const char *describe_relay_port(const struct port_cfg_t *port);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(RELAY_CONFIG_PRIVATE) */

#else /* !defined(HAVE_MODULE_RELAY) */

#include "lib/cc/compat_compiler.h"

/** When tor is compiled with the relay module disabled, it can't be
 * configured as a relay or bridge.
 *
 * Always sets ClientOnly to 1.
 *
 * Returns -1 and sets msg to a newly allocated string, if ORPort, DirPort,
 * DirCache, or BridgeRelay are set in options. Otherwise returns 0. */
static inline int
options_validate_relay_mode(const struct or_options_t *old_options,
                            struct or_options_t *options,
                            char **msg)
{
  (void)old_options;

  /* Only check the primary options for now, #29211 will disable more
   * options. These ORPort and DirPort checks are too strict, and will
   * reject valid configs that disable ports, like "ORPort 0". */
  if (options->DirCache ||
      options->BridgeRelay ||
      options->ORPort_lines ||
      options->DirPort_lines) {
    /* REJECT() this configuration */
    *msg = tor_strdup("This tor was built with relay mode disabled. "
                      "It can not be configured with an ORPort, a DirPort, "
                      "DirCache 1, or BridgeRelay 1.");
    return -1;
  }

  return 0;
}

static inline int
port_parse_ports_relay(or_options_t *options,
                       char **msg,
                       smartlist_t *ports_out,
                       int *have_low_ports_out)
{
  (void)options;
  (void)msg;
  (void)ports_out;
  if (*have_low_ports_out < 0)
    *have_low_ports_out = 0;
  return 0;
}

#define relay_get_dirportfrontpage() \
  (NULL)
#define relay_config_free_all() \
  STMT_BEGIN STMT_END

#define relay_get_effective_bwrate(options) \
  (((void)(options)),0)
#define relay_get_effective_bwburst(options) \
  (((void)(options)),0)

#define port_warn_nonlocal_ext_orports(ports, portname) \
  (((void)(ports)),((void)(portname)))

#define port_update_port_set_relay(options, ports) \
  (((void)(options)),((void)(ports)))

#define options_validate_relay_os(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_validate_relay_info(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_validate_publish_server(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_validate_relay_padding(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_validate_relay_bandwidth(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_validate_relay_accounting(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)
#define options_validate_relay_testing(old_options, options, msg) \
  (((void)(old_options)),((void)(options)),((void)(msg)),0)

#define options_act_relay(old_options) \
  (((void)(old_options)),0)
#define options_act_relay_accounting(old_options) \
  (((void)(old_options)),0)
#define options_act_relay_bandwidth(old_options) \
  (((void)(old_options)),0)
#define options_act_bridge_stats(old_options) \
  (((void)(old_options)),0)

#define options_act_relay_stats(old_options, print_notice_out) \
  (((void)(old_options)),((void)(print_notice_out)),0)
#define options_act_relay_stats_msg() \
  STMT_BEGIN STMT_END

#define options_act_relay_desc(old_options) \
  (((void)(old_options)),0)
#define options_act_relay_dos(old_options) \
  (((void)(old_options)),0)
#define options_act_relay_dir(old_options) \
  (((void)(old_options)),0)

#endif /* defined(HAVE_MODULE_RELAY) */

#endif /* !defined(TOR_FEATURE_RELAY_RELAY_CONFIG_H) */
