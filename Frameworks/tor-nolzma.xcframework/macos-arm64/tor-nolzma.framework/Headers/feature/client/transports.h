/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file transports.h
 * \brief Headers for transports.c
 **/

#ifndef TOR_TRANSPORTS_H
#define TOR_TRANSPORTS_H

#include "lib/process/process.h"

/** Represents a pluggable transport used by a bridge. */
typedef struct transport_t {
  /** SOCKS version: One of PROXY_SOCKS4, PROXY_SOCKS5. */
  int socks_version;
  /** Name of pluggable transport protocol */
  char *name;
  /** The IP address where the transport bound and is waiting for
   * connections. */
  tor_addr_t addr;
  /** Port of proxy */
  uint16_t port;
  /** Boolean: We are re-parsing our transport list, and we are going to remove
   * this one if we don't find it in the list of configured transports. */
  unsigned marked_for_removal : 1;
  /** Arguments for this transport that must be written to the
      extra-info descriptor. */
  char *extra_info_args;
} transport_t;

void mark_transport_list(void);
void sweep_transport_list(void);
MOCK_DECL(int, transport_add_from_config,
          (const tor_addr_t *addr, uint16_t port,
           const char *name, int socks_ver));
void transport_free_(transport_t *transport);
#define transport_free(tr) FREE_AND_NULL(transport_t, transport_free_, (tr))

MOCK_DECL(transport_t*, transport_get_by_name, (const char *name));
bool managed_proxy_has_transport(const char *transport_name);

MOCK_DECL(void, pt_kickstart_proxy,
          (const smartlist_t *transport_list, char **proxy_argv,
           int is_server));

#define pt_kickstart_client_proxy(tl, pa)  \
  pt_kickstart_proxy(tl, pa, 0)
#define pt_kickstart_server_proxy(tl, pa) \
  pt_kickstart_proxy(tl, pa, 1)

void pt_configure_remaining_proxies(void);

int pt_proxies_configuration_pending(void);

char *pt_get_extra_info_descriptor_string(void);

void pt_free_all(void);

void pt_prepare_proxy_list_for_config_read(void);
void sweep_proxy_list(void);

smartlist_t *get_transport_proxy_ports(void);
char *pt_stringify_socks_args(const smartlist_t *socks_args);

char *pt_get_socks_args_for_proxy_addrport(const tor_addr_t *addr,
                                            uint16_t port);

char *tor_escape_str_for_pt_args(const char *string,
                                 const char *chars_to_escape);

#ifdef PT_PRIVATE
/** State of the managed proxy configuration protocol. */
enum pt_proto_state {
  PT_PROTO_INFANT, /* was just born */
  PT_PROTO_LAUNCHED, /* was just launched */
  PT_PROTO_ACCEPTING_METHODS, /* accepting methods */
  PT_PROTO_CONFIGURED, /* configured successfully */
  PT_PROTO_COMPLETED, /* configure and registered its transports */
  PT_PROTO_BROKEN, /* broke during the protocol */
  PT_PROTO_FAILED_LAUNCH /* failed while launching */
};

struct process_t;

/** Structure containing information of a managed proxy. */
typedef struct {
  enum pt_proto_state conf_state; /* the current configuration state */
  char **argv; /* the cli arguments of this proxy */
  int conf_protocol; /* the configuration protocol version used */

  char *proxy_uri;  /* the outgoing proxy in TOR_PT_PROXY URI format */
  unsigned int proxy_supported : 1; /* the proxy honors TOR_PT_PROXY */

  int is_server; /* is it a server proxy? */

  /* A pointer to the process of this managed proxy. */
  struct process_t *process;

  /** Boolean: We are re-parsing our config, and we are going to
   * remove this managed proxy if we don't find it any transport
   * plugins that use it. */
  unsigned int marked_for_removal : 1;

  /** Boolean: We got a SIGHUP while this proxy was running. We use
   * this flag to signify that this proxy might need to be restarted
   * so that it can listen for other transports according to the new
   * torrc. */
  unsigned int was_around_before_config_read : 1;

  /* transports to-be-launched by this proxy */
  smartlist_t *transports_to_launch;

  /** Version as set by STATUS TYPE=version messages. */
  char *version;

  /** Implementation as set by the STATUS TYPE=version messages. */
  char *implementation;

  /* The 'transports' list contains all the transports this proxy has
     launched. */
  smartlist_t *transports;
} managed_proxy_t;

struct config_line_t;

STATIC transport_t *transport_new(const tor_addr_t *addr, uint16_t port,
                                  const char *name, int socks_ver,
                                  const char *extra_info_args);
STATIC int parse_cmethod_line(const char *line, managed_proxy_t *mp);
STATIC int parse_smethod_line(const char *line, managed_proxy_t *mp);

STATIC int parse_version(const char *line, managed_proxy_t *mp);
STATIC void parse_env_error(const char *line);
STATIC void parse_proxy_error(const char *line);
STATIC void handle_proxy_line(const char *line, managed_proxy_t *mp);
STATIC void parse_log_line(const char *line, managed_proxy_t *mp);
STATIC void parse_status_line(const char *line, managed_proxy_t *mp);
STATIC void handle_status_message(const struct config_line_t *values,
                                  managed_proxy_t *mp);
STATIC char *get_transport_options_for_server_proxy(const managed_proxy_t *mp);

STATIC void managed_proxy_destroy(managed_proxy_t *mp,
                                  int also_terminate_process);

STATIC managed_proxy_t *managed_proxy_create(const smartlist_t *transport_list,
                                             char **proxy_argv, int is_server);

STATIC int configure_proxy(managed_proxy_t *mp);

STATIC char* get_pt_proxy_uri(void);

STATIC void free_execve_args(char **arg);

STATIC void managed_proxy_stdout_callback(process_t *, const char *, size_t);
STATIC void managed_proxy_stderr_callback(process_t *, const char *, size_t);
STATIC bool managed_proxy_exit_callback(process_t *, process_exit_code_t);

STATIC int managed_proxy_severity_parse(const char *);
STATIC const tor_addr_t *managed_proxy_outbound_address(const or_options_t *,
                                                        sa_family_t);

STATIC const char *managed_proxy_state_to_string(enum pt_proto_state);
STATIC void managed_proxy_set_state(managed_proxy_t *, enum pt_proto_state);
#endif /* defined(PT_PRIVATE) */

#endif /* !defined(TOR_TRANSPORTS_H) */
