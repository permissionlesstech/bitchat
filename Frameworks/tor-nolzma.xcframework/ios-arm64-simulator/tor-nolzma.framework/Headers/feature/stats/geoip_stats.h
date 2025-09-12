/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file geoip_stats.h
 * \brief Header file for geoip_stats.c.
 **/

#ifndef TOR_GEOIP_STATS_H
#define TOR_GEOIP_STATS_H

#include "core/or/dos.h"
#include "ext/ht.h"

/** Indicates an action that we might be noting geoip statistics on.
 * Note that if we're noticing CONNECT, we're a bridge, and if we're noticing
 * the others, we're not.
 */
typedef enum {
  /** An incoming ORPort connection */
  GEOIP_CLIENT_CONNECT = 0,
  /** We've served a networkstatus consensus as a directory server. */
  GEOIP_CLIENT_NETWORKSTATUS = 1,
} geoip_client_action_t;
/** Indicates either a positive reply or a reason for rejectng a network
 * status request that will be included in geoip statistics. */
typedef enum {
  /** Request is answered successfully. */
  GEOIP_SUCCESS = 0,
  /** V3 network status is not signed by a sufficient number of requested
   * authorities. */
  GEOIP_REJECT_NOT_ENOUGH_SIGS = 1,
  /** Requested network status object is unavailable. */
  GEOIP_REJECT_UNAVAILABLE = 2,
  /** Requested network status not found. */
  GEOIP_REJECT_NOT_FOUND = 3,
  /** Network status has not been modified since If-Modified-Since time. */
  GEOIP_REJECT_NOT_MODIFIED = 4,
  /** Directory is busy. */
  GEOIP_REJECT_BUSY = 5,
} geoip_ns_response_t;
#define GEOIP_NS_RESPONSE_NUM 6

/** Directory requests that we are measuring can be either direct or
 * tunneled. */
typedef enum {
  DIRREQ_DIRECT = 0,
  DIRREQ_TUNNELED = 1,
} dirreq_type_t;

/** Possible states for either direct or tunneled directory requests that
 * are relevant for determining network status download times. */
typedef enum {
  /** Found that the client requests a network status; applies to both
   * direct and tunneled requests; initial state of a request that we are
   * measuring. */
  DIRREQ_IS_FOR_NETWORK_STATUS = 0,
  /** Finished writing a network status to the directory connection;
   * applies to both direct and tunneled requests; completes a direct
   * request. */
  DIRREQ_FLUSHING_DIR_CONN_FINISHED = 1,
  /** END cell sent to circuit that initiated a tunneled request. */
  DIRREQ_END_CELL_SENT = 2,
  /** Flushed last cell from queue of the circuit that initiated a
    * tunneled request to the outbuf of the OR connection. */
  DIRREQ_CIRC_QUEUE_FLUSHED = 3,
  /** Flushed last byte from buffer of the channel belonging to the
    * circuit that initiated a tunneled request; completes a tunneled
    * request. */
  DIRREQ_CHANNEL_BUFFER_FLUSHED = 4
} dirreq_state_t;

/** Entry in a map from IP address to the last time we've seen an incoming
 * connection from that IP address. Used by bridges only to track which
 * countries have them blocked, or the DoS mitigation subsystem if enabled. */
typedef struct clientmap_entry_t {
  HT_ENTRY(clientmap_entry_t) node;
  tor_addr_t addr;
  /* Name of pluggable transport used by this client. NULL if no
     pluggable transport was used. */
  char *transport_name;

  /** Time when we last saw this IP address, in MINUTES since the epoch.
   *
   * (This will run out of space around 4011 CE.  If Tor is still in use around
   * 4000 CE, please remember to add more bits to last_seen_in_minutes.) */
  unsigned int last_seen_in_minutes:30;
  unsigned int action:2;

  /* This object is used to keep some statistics per client address for the
   * DoS mitigation subsystem. */
  dos_client_stats_t dos_stats;
} clientmap_entry_t;

int should_record_bridge_info(const or_options_t *options);

void geoip_note_client_seen(geoip_client_action_t action,
                            const tor_addr_t *addr, const char *transport_name,
                            time_t now);
void geoip_remove_old_clients(time_t cutoff);
clientmap_entry_t *geoip_lookup_client(const tor_addr_t *addr,
                                       const char *transport_name,
                                       geoip_client_action_t action);
size_t geoip_client_cache_total_allocation(void);
size_t geoip_client_cache_handle_oom(time_t now, size_t min_remove_bytes);

void geoip_note_ns_response(geoip_ns_response_t response);
char *geoip_get_transport_history(void);
int geoip_get_client_history(geoip_client_action_t action,
                             char **country_str, char **ipver_str);
char *geoip_get_request_history(void);
void geoip_stats_free_all(void);

void geoip_start_dirreq(uint64_t dirreq_id, size_t response_size,
                        dirreq_type_t type);
void geoip_change_dirreq_state(uint64_t dirreq_id, dirreq_type_t type,
                               dirreq_state_t new_state);

void geoip_dirreq_stats_init(time_t now);
void geoip_reset_dirreq_stats(time_t now);
char *geoip_format_dirreq_stats(time_t now);
time_t geoip_dirreq_stats_write(time_t now);
void geoip_dirreq_stats_term(void);
void geoip_entry_stats_init(time_t now);
time_t geoip_entry_stats_write(time_t now);
void geoip_entry_stats_term(void);
void geoip_reset_entry_stats(time_t now);
char *geoip_format_entry_stats(time_t now);
void geoip_bridge_stats_init(time_t now);
char *geoip_format_bridge_stats(time_t now);
time_t geoip_bridge_stats_write(time_t now);
void geoip_bridge_stats_term(void);
const char *geoip_get_bridge_stats_extrainfo(time_t);
char *geoip_get_bridge_stats_controller(time_t);
char *format_client_stats_heartbeat(time_t now);

#endif /* !defined(TOR_GEOIP_STATS_H) */
