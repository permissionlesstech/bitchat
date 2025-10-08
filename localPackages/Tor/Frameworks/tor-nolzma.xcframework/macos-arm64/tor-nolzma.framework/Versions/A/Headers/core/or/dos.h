/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/*
 * \file dos.h
 * \brief Header file for dos.c
 */

#ifndef TOR_DOS_H
#define TOR_DOS_H

#include "core/or/or.h"

#include "lib/evloop/token_bucket.h"

/* Structure that keeps stats of circuit creation per client connection IP. */
typedef struct cc_client_stats_t {
  /* Number of allocated circuits remaining for this address.  It is
   * decremented every time a new circuit is seen for this client address and
   * if the count goes to 0, we have a positive detection. */
  uint32_t circuit_bucket;

  /* When was the last time we've refilled the circuit bucket? This is used to
   * know if we need to refill the bucket when a new circuit is seen. It is
   * synchronized using approx_time(). */
  time_t last_circ_bucket_refill_ts;

  /* This client address was detected to be above the circuit creation rate
   * and this timestamp indicates until when it should remain marked as
   * detected so we can apply a defense for the address. It is synchronized
   * using the approx_time(). */
  time_t marked_until_ts;
} cc_client_stats_t;

/* Structure that keeps stats of client connection per-IP. */
typedef struct conn_client_stats_t {
  /* Concurrent connection count from the specific address. 2^32 - 1 is most
   * likely way too big for the amount of allowed file descriptors. */
  uint32_t concurrent_count;

  /* Connect count from the specific address. We use a token bucket here to
   * track the rate and burst of connections from the same IP address.*/
  token_bucket_ctr_t connect_count;

  /* The client address attempted too many connections, per the connect_count
   * rules, and thus is marked so defense(s) can be applied. It is
   * synchronized using the approx_time(). */
  time_t marked_until_ts;
} conn_client_stats_t;

/* This object is a top level object that contains everything related to the
 * per-IP client DoS mitigation. Because it is per-IP, it is used in the geoip
 * clientmap_entry_t object. */
typedef struct dos_client_stats_t {
  /* Client connection statistics. */
  conn_client_stats_t conn_stats;

  /* Circuit creation statistics. This is only used if the circuit creation
   * subsystem has been enabled (dos_cc_enabled). */
  cc_client_stats_t cc_stats;

  /** Number of times the circ_max_cell_queue_size limit has been reached. */
  uint32_t num_circ_max_cell_queue_size;
} dos_client_stats_t;

/* General API. */

/* Stub. */
struct clientmap_entry_t;

void dos_init(void);
void dos_free_all(void);
void dos_consensus_has_changed(const networkstatus_t *ns);
int dos_enabled(void);
void dos_log_heartbeat(void);
void dos_geoip_entry_init(struct clientmap_entry_t *geoip_ent);
void dos_geoip_entry_about_to_free(const struct clientmap_entry_t *geoip_ent);

void dos_new_client_conn(or_connection_t *or_conn,
                         const char *transport_name);
void dos_close_client_conn(const or_connection_t *or_conn);

int dos_should_refuse_single_hop_client(void);
void dos_note_refuse_single_hop_client(void);
void dos_note_circ_max_outq(const channel_t *chan);

uint32_t dos_get_num_cc_marked_addr(void);
uint32_t dos_get_num_cc_marked_addr_maxq(void);
uint64_t dos_get_num_cc_rejected(void);
uint64_t dos_get_num_conn_addr_rejected(void);
uint64_t dos_get_num_conn_addr_connect_rejected(void);
uint64_t dos_get_num_single_hop_refused(void);

/*
 * Circuit creation DoS mitigation subsystemn interface.
 */

/* DoSCircuitCreationEnabled default. Disabled by default. */
#define DOS_CC_ENABLED_DEFAULT 0
/* DoSCircuitCreationDefenseType maps to the dos_cc_defense_type_t enum. */
#define DOS_CC_DEFENSE_TYPE_DEFAULT DOS_CC_DEFENSE_REFUSE_CELL
/* DoSCircuitCreationMinConnections default */
#define DOS_CC_MIN_CONCURRENT_CONN_DEFAULT 3
/* DoSCircuitCreationRateTenths is 3 per seconds. */
#define DOS_CC_CIRCUIT_RATE_DEFAULT 3
/* DoSCircuitCreationBurst default. */
#define DOS_CC_CIRCUIT_BURST_DEFAULT 90
/* DoSCircuitCreationDefenseTimePeriod in seconds. */
#define DOS_CC_DEFENSE_TIME_PERIOD_DEFAULT (60 * 60)

/* Type of defense that we can use for the circuit creation DoS mitigation. */
typedef enum dos_cc_defense_type_t {
  /* No defense used. */
  DOS_CC_DEFENSE_NONE             = 1,
  /* Refuse any cells which means a DESTROY cell will be sent back. */
  DOS_CC_DEFENSE_REFUSE_CELL      = 2,

  /* Maximum value that can be used. Useful for the boundaries of the
   * consensus parameter. */
  DOS_CC_DEFENSE_MAX              = 2,
} dos_cc_defense_type_t;

void dos_cc_new_create_cell(channel_t *channel);
dos_cc_defense_type_t dos_cc_get_defense_type(channel_t *chan);

/*
 * Concurrent connection DoS mitigation interface.
 */

/* DoSConnectionEnabled default. Disabled by default. */
#define DOS_CONN_ENABLED_DEFAULT 0
/* DoSConnectionMaxConcurrentCount default. */
#define DOS_CONN_MAX_CONCURRENT_COUNT_DEFAULT 100
/* DoSConnectionDefenseType maps to the dos_conn_defense_type_t enum. */
#define DOS_CONN_DEFENSE_TYPE_DEFAULT DOS_CONN_DEFENSE_CLOSE
/* DoSConnectionConnectRate default. Per second. */
#define DOS_CONN_CONNECT_RATE_DEFAULT 20
/* DoSConnectionConnectBurst default. Per second. */
#define DOS_CONN_CONNECT_BURST_DEFAULT 40
/* DoSConnectionConnectDefenseTimePeriod default. Set to 24 hours. */
#define DOS_CONN_CONNECT_DEFENSE_TIME_PERIOD_DEFAULT (24 * 60 * 60)
/* DoSCircuitCreationDefenseTimePeriod minimum value. Because we add a random
 * offset to the marked timestamp, we need the minimum value to be non zero.
 * We consider that 10 seconds is an acceptable lower bound. */
#define DOS_CONN_CONNECT_DEFENSE_TIME_PERIOD_MIN (10)

/* Type of defense that we can use for the concurrent connection DoS
 * mitigation. */
typedef enum dos_conn_defense_type_t {
  /* No defense used. */
  DOS_CONN_DEFENSE_NONE             = 1,
  /* Close immediately the connection meaning refuse it. */
  DOS_CONN_DEFENSE_CLOSE            = 2,

  /* Maximum value that can be used. Useful for the boundaries of the
   * consensus parameter. */
  DOS_CONN_DEFENSE_MAX              = 2,
} dos_conn_defense_type_t;

dos_conn_defense_type_t dos_conn_addr_get_defense_type(const tor_addr_t *addr);

#ifdef DOS_PRIVATE

STATIC uint32_t get_param_conn_max_concurrent_count(
                                              const networkstatus_t *ns);
STATIC uint32_t get_param_cc_circuit_burst(const networkstatus_t *ns);
STATIC uint32_t get_param_cc_min_concurrent_connection(
                                            const networkstatus_t *ns);
STATIC uint32_t get_param_conn_connect_burst(const networkstatus_t *ns);

STATIC uint64_t get_circuit_rate_per_second(void);
STATIC void cc_stats_refill_bucket(cc_client_stats_t *stats,
                                   const tor_addr_t *addr);

MOCK_DECL(STATIC unsigned int, get_param_cc_enabled,
          (const networkstatus_t *ns));
MOCK_DECL(STATIC unsigned int, get_param_conn_enabled,
          (const networkstatus_t *ns));

#endif /* defined(DOS_PRIVATE) */

#endif /* !defined(TOR_DOS_H) */

