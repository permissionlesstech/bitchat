/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file config.h
 * \brief Header file for config.c.
 **/

#ifndef TOR_CONFIG_H
#define TOR_CONFIG_H

#include "app/config/or_options_st.h"
#include "lib/testsupport/testsupport.h"
#include "app/config/quiet_level.h"

#if defined(__FreeBSD__) || defined(__FreeBSD_kernel__) || defined(DARWIN)
#define KERNEL_MAY_SUPPORT_IPFW
#endif

/** Lowest allowable value for HeartbeatPeriod; if this is too low, we might
 * expose more information than we're comfortable with. */
#define MIN_HEARTBEAT_PERIOD (30*60)

/** Maximum default value for MaxMemInQueues, in bytes. */
#if SIZEOF_VOID_P >= 8
#define MAX_DEFAULT_MEMORY_QUEUE_SIZE (UINT64_C(8) << 30)
#else
#define MAX_DEFAULT_MEMORY_QUEUE_SIZE (UINT64_C(2) << 30)
#endif

MOCK_DECL(const or_options_t *, get_options, (void));
MOCK_DECL(or_options_t *, get_options_mutable, (void));
int set_options(or_options_t *new_val, char **msg);
void config_free_all(void);
const char *safe_str_client(const char *address);
const char *safe_str(const char *address);
const char *escaped_safe_str_client(const char *address);
const char *escaped_safe_str(const char *address);
void init_protocol_warning_severity_level(void);
int get_protocol_warning_severity_level(void);

#define LOG_PROTOCOL_WARN (get_protocol_warning_severity_level())

/** Pattern for backing up configuration files */
#define CONFIG_BACKUP_PATTERN "%s.orig.1"

/** An error from options_trial_assign() or options_init_from_string(). */
typedef enum setopt_err_t {
  SETOPT_OK = 0,
  SETOPT_ERR_MISC = -1,
  SETOPT_ERR_PARSE = -2,
  SETOPT_ERR_TRANSITION = -3,
  SETOPT_ERR_SETTING = -4,
} setopt_err_t;
setopt_err_t options_trial_assign(struct config_line_t *list, unsigned flags,
                                  char **msg);

void options_init(or_options_t *options);

#define OPTIONS_DUMP_MINIMAL 1
#define OPTIONS_DUMP_ALL 2
char *options_dump(const or_options_t *options, int how_to_dump);
int options_init_from_torrc(int argc, char **argv);
setopt_err_t options_init_from_string(const char *cf_defaults, const char *cf,
                            int command, const char *command_arg, char **msg);
int option_is_recognized(const char *key);
const char *option_get_canonical_name(const char *key);
struct config_line_t *option_get_assignment(const or_options_t *options,
                                     const char *key);
int options_save_current(void);
const char *get_torrc_fname(int defaults_fname);
typedef enum {
  DIRROOT_DATADIR,
  DIRROOT_CACHEDIR,
  DIRROOT_KEYDIR
} directory_root_t;

MOCK_DECL(char *,
          options_get_dir_fname2_suffix,
          (const or_options_t *options,
           directory_root_t roottype,
           const char *sub1, const char *sub2,
           const char *suffix));

/* These macros wrap options_get_dir_fname2_suffix to provide a more
 * convenient API for finding filenames that Tor uses inside its storage
 * They are named according to a pattern:
 *    (options_)?get_(cache|key|data)dir_fname(2)?(_suffix)?
 *
 * Macros that begin with options_ take an options argument; the others
 * work with respect to the global options.
 *
 * Each macro works relative to the data directory, the key directory,
 * or the cache directory, as determined by which one is mentioned.
 *
 * Macro variants with "2" in their name take two path components; others
 * take one.
 *
 * Macro variants with "_suffix" at the end take an additional suffix
 * that gets appended to the end of the file
 */
#define options_get_datadir_fname2_suffix(options, sub1, sub2, suffix) \
  options_get_dir_fname2_suffix((options), DIRROOT_DATADIR, \
                                (sub1), (sub2), (suffix))
#define options_get_cachedir_fname2_suffix(options, sub1, sub2, suffix) \
  options_get_dir_fname2_suffix((options), DIRROOT_CACHEDIR, \
                                (sub1), (sub2), (suffix))
#define options_get_keydir_fname2_suffix(options, sub1, sub2, suffix) \
  options_get_dir_fname2_suffix((options), DIRROOT_KEYDIR, \
                                (sub1), (sub2), (suffix))

#define options_get_datadir_fname(opts,sub1)                    \
  options_get_datadir_fname2_suffix((opts),(sub1), NULL, NULL)
#define options_get_datadir_fname2(opts,sub1,sub2)                      \
  options_get_datadir_fname2_suffix((opts),(sub1), (sub2), NULL)

#define get_datadir_fname2_suffix(sub1, sub2, suffix) \
  options_get_datadir_fname2_suffix(get_options(), (sub1), (sub2), (suffix))
#define get_datadir_fname(sub1)                 \
  get_datadir_fname2_suffix((sub1), NULL, NULL)
#define get_datadir_fname2(sub1,sub2) \
  get_datadir_fname2_suffix((sub1), (sub2), NULL)
#define get_datadir_fname_suffix(sub1, suffix) \
  get_datadir_fname2_suffix((sub1), NULL, (suffix))

/** DOCDOC */
#define options_get_keydir_fname(options, sub1)  \
  options_get_keydir_fname2_suffix((options), (sub1), NULL, NULL)
#define get_keydir_fname_suffix(sub1, suffix)   \
  options_get_keydir_fname2_suffix(get_options(), (sub1), NULL, suffix)
#define get_keydir_fname(sub1)                  \
  options_get_keydir_fname2_suffix(get_options(), (sub1), NULL, NULL)

#define get_cachedir_fname(sub1) \
  options_get_cachedir_fname2_suffix(get_options(), (sub1), NULL, NULL)
#define get_cachedir_fname_suffix(sub1, suffix) \
  options_get_cachedir_fname2_suffix(get_options(), (sub1), NULL, (suffix))

#define safe_str_client(address) \
  safe_str_client_opts(NULL, address)
#define safe_str(address) \
  safe_str_opts(NULL, address)

const char * safe_str_client_opts(const or_options_t *options,
                                  const char *address);
const char * safe_str_opts(const or_options_t *options,
                           const char *address);

int using_default_dir_authorities(const or_options_t *options);

int create_keys_directory(const or_options_t *options);

int check_or_create_data_subdir(const char *subdir);
int write_to_data_subdir(const char* subdir, const char* fname,
                         const char* str, const char* descr);

int get_num_cpus(const or_options_t *options);

MOCK_DECL(const smartlist_t *,get_configured_ports,(void));
int port_binds_ipv4(const port_cfg_t *port);
int port_binds_ipv6(const port_cfg_t *port);
int portconf_get_first_advertised_port(int listener_type,
                                       int address_family);
#define portconf_get_primary_dir_port() \
  (portconf_get_first_advertised_port(CONN_TYPE_DIR_LISTENER, AF_INET))
const tor_addr_t *portconf_get_first_advertised_addr(int listener_type,
                                                       int address_family);
int port_exists_by_type_addr_port(int listener_type, const tor_addr_t *addr,
                                  int port, int check_wildcard);
int port_exists_by_type_addr32h_port(int listener_type, uint32_t addr_ipv4h,
                                     int port, int check_wildcard);

char *get_first_listener_addrport_string(int listener_type);

int options_need_geoip_info(const or_options_t *options,
                            const char **reason_out);

int getinfo_helper_config(control_connection_t *conn,
                          const char *question, char **answer,
                          const char **errmsg);

int init_cookie_authentication(const char *fname, const char *header,
                               int cookie_len, int group_readable,
                               uint8_t **cookie_out, int *cookie_is_set_out);

or_options_t *options_new(void);

/** Options settings parsed from the command-line. */
typedef struct {
  /** List of options that can only be set from the command-line */
  struct config_line_t *cmdline_opts;
  /** List of other options, to be handled by the general Tor configuration
      system. */
  struct config_line_t *other_opts;
  /** Subcommand that Tor has been told to run */
  tor_cmdline_mode_t command;
  /** Argument for the command mode, if any. */
  const char *command_arg;
  /** How quiet have we been told to be? */
  quiet_level_t quiet_level;
} parsed_cmdline_t;

parsed_cmdline_t *config_parse_commandline(int argc, char **argv,
                                           int ignore_errors);
void parsed_cmdline_free_(parsed_cmdline_t *cmdline);
#define parsed_cmdline_free(c) \
  FREE_AND_NULL(parsed_cmdline_t, parsed_cmdline_free_, (c))

void config_register_addressmaps(const or_options_t *options);
/* XXXX move to connection_edge.h */
int addressmap_register_auto(const char *from, const char *to,
                             time_t expires,
                             addressmap_entry_source_t addrmap_source,
                             const char **msg);

int port_cfg_line_extract_addrport(const char *line,
                                   char **addrport_out,
                                   int *is_unix_out,
                                   const char **rest_out);

/** Represents the information stored in a torrc Bridge line. */
typedef struct bridge_line_t {
  tor_addr_t addr; /* The IP address of the bridge. */
  uint16_t port; /* The TCP port of the bridge. */
  char *transport_name; /* The name of the pluggable transport that
                           should be used to connect to the bridge. */
  char digest[DIGEST_LEN]; /* The bridge's identity key digest. */
  smartlist_t *socks_args; /* SOCKS arguments for the pluggable
                               transport proxy. */
} bridge_line_t;

void bridge_line_free_(bridge_line_t *bridge_line);
#define bridge_line_free(line) \
  FREE_AND_NULL(bridge_line_t, bridge_line_free_, (line))
bridge_line_t *parse_bridge_line(const char *line);

/* Port helper functions. */
int options_any_client_port_set(const or_options_t *options);
int port_parse_config(smartlist_t *out,
                      const struct config_line_t *ports,
                      const char *portname,
                      int listener_type,
                      const char *defaultaddr,
                      int defaultport,
                      const unsigned flags);

#define CL_PORT_NO_STREAM_OPTIONS (1u<<0)
#define CL_PORT_WARN_NONLOCAL (1u<<1)
/* Was CL_PORT_ALLOW_EXTRA_LISTENADDR (1u<<2) */
#define CL_PORT_SERVER_OPTIONS (1u<<3)
#define CL_PORT_FORBID_NONLOCAL (1u<<4)
#define CL_PORT_TAKES_HOSTNAMES (1u<<5)
#define CL_PORT_IS_UNIXSOCKET (1u<<6)
#define CL_PORT_DFLT_GROUP_WRITABLE (1u<<7)

port_cfg_t *port_cfg_new(size_t namelen);
#define port_cfg_free(port) \
  FREE_AND_NULL(port_cfg_t, port_cfg_free_, (port))
void port_cfg_free_(port_cfg_t *port);

int port_count_real_listeners(const smartlist_t *ports,
                         int listenertype,
                         int count_sockets);
int pt_parse_transport_line(const or_options_t *options,
                         const char *line, int validate_only,
                         int server);
int config_ensure_bandwidth_cap(uint64_t *value, const char *desc, char **msg);

#ifdef CONFIG_PRIVATE

MOCK_DECL(STATIC int, options_act,(const or_options_t *old_options));
MOCK_DECL(STATIC int, options_act_reversible,(const or_options_t *old_options,
                                             char **msg));
struct config_mgr_t;
STATIC const struct config_mgr_t *get_options_mgr(void);

#define or_options_free(opt) \
  FREE_AND_NULL(or_options_t, or_options_free_, (opt))
STATIC void or_options_free_(or_options_t *options);
STATIC int options_validate_single_onion(or_options_t *options,
                                         char **msg);
STATIC int parse_tcp_proxy_line(const char *line, or_options_t *options,
                                char **msg);
STATIC int consider_adding_dir_servers(const or_options_t *options,
                                       const or_options_t *old_options);
STATIC void add_default_trusted_dir_authorities(dirinfo_type_t type);
MOCK_DECL(STATIC void, add_default_fallback_dir_servers, (void));
STATIC int parse_dir_authority_line(const char *line,
                                    dirinfo_type_t required_type,
                                    int validate_only);
STATIC int parse_dir_fallback_line(const char *line, int validate_only);

STATIC uint64_t compute_real_max_mem_in_queues(const uint64_t val,
                                               bool is_server);
STATIC int open_and_add_file_log(const log_severity_list_t *severity,
                                 const char *fname,
                                 int truncate_log);
STATIC int options_init_logs(const or_options_t *old_options,
                             const or_options_t *options, int validate_only);

STATIC int options_create_directories(char **msg_out);
struct log_transaction_t;
STATIC struct log_transaction_t *options_start_log_transaction(
                              const or_options_t *old_options,
                              char **msg_out);
STATIC void options_commit_log_transaction(struct log_transaction_t *xn);
STATIC void options_rollback_log_transaction(struct log_transaction_t *xn);

#ifdef TOR_UNIT_TESTS
int options_validate(const or_options_t *old_options,
                     or_options_t *options,
                     char **msg);
#endif

STATIC int parse_ports(or_options_t *options, int validate_only,
                       char **msg, int *n_ports_out,
                       int *world_writable_control_socket);

#endif /* defined(CONFIG_PRIVATE) */

#endif /* !defined(TOR_CONFIG_H) */
