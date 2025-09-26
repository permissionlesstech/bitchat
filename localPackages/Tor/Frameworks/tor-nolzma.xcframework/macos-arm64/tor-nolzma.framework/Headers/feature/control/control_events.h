/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control_events.h
 * \brief Header file for control_events.c.
 **/

#ifndef TOR_CONTROL_EVENTS_H
#define TOR_CONTROL_EVENTS_H

#include "lib/cc/ctassert.h"
#include "core/or/ocirc_event.h"
#include "core/or/orconn_event.h"

struct config_line_t;

/** Used to indicate the type of a CIRC_MINOR event passed to the controller.
 * The various types are defined in control-spec.txt . */
typedef enum circuit_status_minor_event_t {
  CIRC_MINOR_EVENT_PURPOSE_CHANGED,
  CIRC_MINOR_EVENT_CANNIBALIZED,
} circuit_status_minor_event_t;

/** Used to indicate the type of a stream event passed to the controller.
 * The various types are defined in control-spec.txt */
typedef enum stream_status_event_t {
  STREAM_EVENT_SENT_CONNECT = 0,
  STREAM_EVENT_SENT_RESOLVE = 1,
  STREAM_EVENT_SUCCEEDED    = 2,
  STREAM_EVENT_FAILED       = 3,
  STREAM_EVENT_CLOSED       = 4,
  STREAM_EVENT_NEW          = 5,
  STREAM_EVENT_NEW_RESOLVE  = 6,
  STREAM_EVENT_FAILED_RETRIABLE = 7,
  STREAM_EVENT_REMAP        = 8,
  STREAM_EVENT_CONTROLLER_WAIT = 9,
  STREAM_EVENT_XOFF_SENT = 10,
  STREAM_EVENT_XOFF_RECV = 11,
  STREAM_EVENT_XON_SENT = 12,
  STREAM_EVENT_XON_RECV = 13
} stream_status_event_t;

/** Used to indicate the type of a buildtime event */
typedef enum buildtimeout_set_event_t {
  BUILDTIMEOUT_SET_EVENT_COMPUTED  = 0,
  BUILDTIMEOUT_SET_EVENT_RESET     = 1,
  BUILDTIMEOUT_SET_EVENT_SUSPENDED = 2,
  BUILDTIMEOUT_SET_EVENT_DISCARD = 3,
  BUILDTIMEOUT_SET_EVENT_RESUME = 4
} buildtimeout_set_event_t;

/** Enum describing various stages of bootstrapping, for use with controller
 * bootstrap status events. The values range from 0 to 100. */
typedef enum {
  BOOTSTRAP_STATUS_UNDEF=-1,
  BOOTSTRAP_STATUS_STARTING=0,

  /* Initial connection to any relay */

  BOOTSTRAP_STATUS_CONN_PT=1,
  BOOTSTRAP_STATUS_CONN_DONE_PT=2,
  BOOTSTRAP_STATUS_CONN_PROXY=3,
  BOOTSTRAP_STATUS_CONN_DONE_PROXY=4,
  BOOTSTRAP_STATUS_CONN=5,
  BOOTSTRAP_STATUS_CONN_DONE=10,
  BOOTSTRAP_STATUS_HANDSHAKE=14,
  BOOTSTRAP_STATUS_HANDSHAKE_DONE=15,

  /* Loading directory info */

  BOOTSTRAP_STATUS_ONEHOP_CREATE=20,
  BOOTSTRAP_STATUS_REQUESTING_STATUS=25,
  BOOTSTRAP_STATUS_LOADING_STATUS=30,
  BOOTSTRAP_STATUS_LOADING_KEYS=40,
  BOOTSTRAP_STATUS_REQUESTING_DESCRIPTORS=45,
  BOOTSTRAP_STATUS_LOADING_DESCRIPTORS=50,
  BOOTSTRAP_STATUS_ENOUGH_DIRINFO=75,

  /* Connecting to a relay for AP circuits */

  BOOTSTRAP_STATUS_AP_CONN_PT=76,
  BOOTSTRAP_STATUS_AP_CONN_DONE_PT=77,
  BOOTSTRAP_STATUS_AP_CONN_PROXY=78,
  BOOTSTRAP_STATUS_AP_CONN_DONE_PROXY=79,
  BOOTSTRAP_STATUS_AP_CONN=80,
  BOOTSTRAP_STATUS_AP_CONN_DONE=85,
  BOOTSTRAP_STATUS_AP_HANDSHAKE=89,
  BOOTSTRAP_STATUS_AP_HANDSHAKE_DONE=90,

  /* Creating AP circuits */

  BOOTSTRAP_STATUS_CIRCUIT_CREATE=95,
  BOOTSTRAP_STATUS_DONE=100
} bootstrap_status_t;

/** Reason for remapping an AP connection's address: we have a cached
 * answer. */
#define REMAP_STREAM_SOURCE_CACHE 1
/** Reason for remapping an AP connection's address: the exit node told us an
 * answer. */
#define REMAP_STREAM_SOURCE_EXIT 2

void control_initialize_event_queue(void);

void control_update_global_event_mask(void);
void control_adjust_event_log_severity(void);

#define EVENT_NS 0x000F
int control_event_is_interesting(int event);

void control_per_second_events(void);
int control_any_per_second_event_enabled(void);

int control_event_circuit_status(origin_circuit_t *circ,
                                 circuit_status_event_t e, int reason);
int control_event_circuit_purpose_changed(origin_circuit_t *circ,
                                          int old_purpose);
int control_event_circuit_cannibalized(origin_circuit_t *circ,
                                       int old_purpose,
                                       const struct timeval *old_tv_created);
int control_event_stream_status(entry_connection_t *conn,
                                stream_status_event_t e,
                                int reason);
int control_event_or_conn_status(or_connection_t *conn,
                                 or_conn_status_event_t e, int reason);
int control_event_bandwidth_used(uint32_t n_read, uint32_t n_written);
int control_event_stream_bandwidth(edge_connection_t *edge_conn);
int control_event_stream_bandwidth_used(void);
int control_event_circ_bandwidth_used(void);
int control_event_circ_bandwidth_used_for_circ(origin_circuit_t *ocirc);
int control_event_conn_bandwidth(connection_t *conn);
int control_event_conn_bandwidth_used(void);
int control_event_circuit_cell_stats(void);
void control_event_logmsg(int severity, log_domain_mask_t domain,
                          const char *msg);
void control_event_logmsg_pending(void);
int control_event_descriptors_changed(smartlist_t *routers);
int control_event_address_mapped(const char *from, const char *to,
                                 time_t expires, const char *error,
                                 const int cached, uint64_t stream_id);
int control_event_my_descriptor_changed(void);
int control_event_network_liveness_update(int liveness);
int control_event_networkstatus_changed(smartlist_t *statuses);

int control_event_newconsensus(const networkstatus_t *consensus);
int control_event_networkstatus_changed_single(const routerstatus_t *rs);
int control_event_general_status(int severity, const char *format, ...)
  CHECK_PRINTF(2,3);
int control_event_client_status(int severity, const char *format, ...)
  CHECK_PRINTF(2,3);
int control_event_server_status(int severity, const char *format, ...)
  CHECK_PRINTF(2,3);

int control_event_general_error(const char *format, ...)
  CHECK_PRINTF(1,2);
int control_event_client_error(const char *format, ...)
  CHECK_PRINTF(1,2);
int control_event_server_error(const char *format, ...)
  CHECK_PRINTF(1,2);

int control_event_guard(const char *nickname, const char *digest,
                        const char *status);
void control_event_conf_changed(const struct config_line_t *changes);
int control_event_buildtimeout_set(buildtimeout_set_event_t type,
                                   const char *args);
int control_event_signal(uintptr_t signal);

void control_event_bootstrap(bootstrap_status_t status, int progress);
int control_get_bootstrap_percent(void);
MOCK_DECL(void, control_event_bootstrap_prob_or,(const char *warn,
                                                 int reason,
                                                 or_connection_t *or_conn));
void control_event_boot_dir(bootstrap_status_t status, int progress);
void control_event_boot_first_orconn(void);
void control_event_bootstrap_problem(const char *warn, const char *reason,
                                     const connection_t *conn, int dowarn);
char *control_event_boot_last_msg(void);
void control_event_bootstrap_reset(void);

void control_event_clients_seen(const char *controller_str);
void control_event_transport_launched(const char *mode,
                                      const char *transport_name,
                                      tor_addr_t *addr, uint16_t port);
void control_event_pt_log(const char *log);
void control_event_pt_status(const char *status);

void control_event_hs_descriptor_requested(const char *onion_address,
                                           rend_auth_type_t auth_type,
                                           const char *id_digest,
                                           const char *desc_id,
                                           const char *hsdir_index);
void control_event_hs_descriptor_created(const char *onion_address,
                                         const char *desc_id,
                                         int replica);
void control_event_hs_descriptor_upload(const char *onion_address,
                                        const char *desc_id,
                                        const char *hs_dir,
                                        const char *hsdir_index);
void control_event_hs_descriptor_upload_end(const char *action,
                                            const char *onion_address,
                                            const char *hs_dir,
                                            const char *reason);
void control_event_hs_descriptor_uploaded(const char *hs_dir,
                                          const char *onion_address);
/* Hidden service v3 HS_DESC specific. */
void control_event_hsv3_descriptor_failed(const char *onion_address,
                                          const char *desc_id,
                                          const char *hsdir_id_digest,
                                          const char *reason);
void control_event_hsv3_descriptor_received(const char *onion_address,
                                            const char *desc_id,
                                            const char *hsdir_id_digest);
void control_event_hs_descriptor_upload_failed(const char *hs_dir,
                                               const char *onion_address,
                                               const char *reason);
void control_event_hs_descriptor_content(const char *onion_address,
                                         const char *desc_id,
                                         const char *hsdir_fp,
                                         const char *content);
void cbt_control_event_buildtimeout_set(const circuit_build_times_t *cbt,
                                        buildtimeout_set_event_t type);

int control_event_enter_controller_wait(void);

void control_events_free_all(void);

#ifdef CONTROL_MODULE_PRIVATE
char *get_bw_samples(void);
#endif /* defined(CONTROL_MODULE_PRIVATE) */

#ifdef CONTROL_EVENTS_PRIVATE
/** Bitfield: The bit 1&lt;&lt;e is set if <b>any</b> open control
 * connection is interested in events of type <b>e</b>.  We use this
 * so that we can decide to skip generating event messages that nobody
 * has interest in without having to walk over the global connection
 * list to find out.
 **/
typedef uint64_t event_mask_t;

/* Recognized asynchronous event types.  It's okay to expand this list
 * because it is used both as a list of v0 event types, and as indices
 * into the bitfield to determine which controllers want which events.
 */
/* This bitfield has no event zero    0x0000 */
#define EVENT_MIN_                    0x0001
#define EVENT_CIRCUIT_STATUS          0x0001
#define EVENT_STREAM_STATUS           0x0002
#define EVENT_OR_CONN_STATUS          0x0003
#define EVENT_BANDWIDTH_USED          0x0004
#define EVENT_CIRCUIT_STATUS_MINOR    0x0005
#define EVENT_NEW_DESC                0x0006
#define EVENT_DEBUG_MSG               0x0007
#define EVENT_INFO_MSG                0x0008
#define EVENT_NOTICE_MSG              0x0009
#define EVENT_WARN_MSG                0x000A
#define EVENT_ERR_MSG                 0x000B
#define EVENT_ADDRMAP                 0x000C
/* There was an AUTHDIR_NEWDESCS event, but it no longer exists.  We
   can reclaim 0x000D. */
#define EVENT_DESCCHANGED             0x000E
/* Exposed above */
// #define EVENT_NS                   0x000F
#define EVENT_STATUS_CLIENT           0x0010
#define EVENT_STATUS_SERVER           0x0011
#define EVENT_STATUS_GENERAL          0x0012
#define EVENT_GUARD                   0x0013
#define EVENT_STREAM_BANDWIDTH_USED   0x0014
#define EVENT_CLIENTS_SEEN            0x0015
#define EVENT_NEWCONSENSUS            0x0016
#define EVENT_BUILDTIMEOUT_SET        0x0017
#define EVENT_GOT_SIGNAL              0x0018
#define EVENT_CONF_CHANGED            0x0019
#define EVENT_CONN_BW                 0x001A
#define EVENT_CELL_STATS              0x001B
/* UNUSED :                           0x001C */
#define EVENT_CIRC_BANDWIDTH_USED     0x001D
#define EVENT_TRANSPORT_LAUNCHED      0x0020
#define EVENT_HS_DESC                 0x0021
#define EVENT_HS_DESC_CONTENT         0x0022
#define EVENT_NETWORK_LIVENESS        0x0023
#define EVENT_PT_LOG                  0x0024
#define EVENT_PT_STATUS               0x0025
#define EVENT_MAX_                    0x0025

/* sizeof(control_connection_t.event_mask) in bits, currently a uint64_t */
#define EVENT_CAPACITY_               0x0040

/* If EVENT_MAX_ ever hits 0x0040, we need to make the mask into a
 * different structure, as it can only handle a maximum left shift of 1<<63. */
CTASSERT(EVENT_MAX_ < EVENT_CAPACITY_);

#define EVENT_MASK_(e)               (((uint64_t)1)<<(e))

#define EVENT_MASK_NONE_             ((uint64_t)0x0)

#define EVENT_MASK_ABOVE_MIN_        ((~((uint64_t)0x0)) << EVENT_MIN_)
#define EVENT_MASK_BELOW_MAX_        ((~((uint64_t)0x0)) \
                                      >> (EVENT_CAPACITY_ - EVENT_MAX_ \
                                          - EVENT_MIN_))

#define EVENT_MASK_ALL_              (EVENT_MASK_ABOVE_MIN_ \
                                      & EVENT_MASK_BELOW_MAX_)

/** Helper structure: temporarily stores cell statistics for a circuit. */
typedef struct cell_stats_t {
  /** Number of cells added in app-ward direction by command. */
  uint64_t added_cells_appward[CELL_COMMAND_MAX_ + 1];
  /** Number of cells added in exit-ward direction by command. */
  uint64_t added_cells_exitward[CELL_COMMAND_MAX_ + 1];
  /** Number of cells removed in app-ward direction by command. */
  uint64_t removed_cells_appward[CELL_COMMAND_MAX_ + 1];
  /** Number of cells removed in exit-ward direction by command. */
  uint64_t removed_cells_exitward[CELL_COMMAND_MAX_ + 1];
  /** Total waiting time of cells in app-ward direction by command. */
  uint64_t total_time_appward[CELL_COMMAND_MAX_ + 1];
  /** Total waiting time of cells in exit-ward direction by command. */
  uint64_t total_time_exitward[CELL_COMMAND_MAX_ + 1];
} cell_stats_t;

void sum_up_cell_stats_by_command(circuit_t *circ,
                                  cell_stats_t *cell_stats);
void append_cell_stats_by_command(smartlist_t *event_parts,
                                  const char *key,
                                  const uint64_t *include_if_non_zero,
                                  const uint64_t *number_to_include);
void format_cell_stats(char **event_string, circuit_t *circ,
                       cell_stats_t *cell_stats);

/** Helper structure: maps event values to their names. */
struct control_event_t {
  uint16_t event_code;
  const char *event_name;
};

extern const struct control_event_t control_event_table[];

void control_logmsg_strip_newlines(char *msg);

#ifdef TOR_UNIT_TESTS
MOCK_DECL(STATIC void,
          send_control_event_string,(uint16_t event, const char *msg));

MOCK_DECL(STATIC void,
          queue_control_event_string,(uint16_t event, char *msg));

void control_testing_set_global_event_mask(uint64_t mask);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(CONTROL_EVENTS_PRIVATE) */

#endif /* !defined(TOR_CONTROL_EVENTS_H) */
