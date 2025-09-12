/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file rephist.h
 * \brief Header file for rephist.c.
 **/

#ifndef TOR_REPHIST_H
#define TOR_REPHIST_H

void rep_hist_init(void);
void rep_hist_dump_stats(time_t now, int severity);

void rep_hist_make_router_pessimal(const char *id, time_t when);

void rep_history_clean(time_t before);

void rep_hist_note_router_reachable(const char *id, const tor_addr_t *at_addr,
                                    const uint16_t at_port, time_t when);
void rep_hist_note_router_unreachable(const char *id, time_t when);
int rep_hist_record_mtbf_data(time_t now, int missing_means_down);
int rep_hist_load_mtbf_data(time_t now);

time_t rep_hist_downrate_old_runs(time_t now);
long rep_hist_get_uptime(const char *id, time_t when);
double rep_hist_get_stability(const char *id, time_t when);
double rep_hist_get_weighted_fractional_uptime(const char *id, time_t when);
long rep_hist_get_weighted_time_known(const char *id, time_t when);
int rep_hist_have_measured_enough_stability(void);

void rep_hist_exit_stats_init(time_t now);
void rep_hist_reset_exit_stats(time_t now);
void rep_hist_exit_stats_term(void);
char *rep_hist_format_exit_stats(time_t now);
time_t rep_hist_exit_stats_write(time_t now);
void rep_hist_note_exit_bytes(uint16_t port, size_t num_written,
                              size_t num_read);
void rep_hist_note_exit_stream_opened(uint16_t port);

void rep_hist_note_conn_opened(bool initiated, unsigned int type, int af);
void rep_hist_note_conn_closed(bool initiated, unsigned int type, int af);
void rep_hist_note_conn_rejected(unsigned int type, int af);
uint64_t rep_hist_get_conn_created(bool initiated, unsigned int type, int af);
uint64_t rep_hist_get_conn_opened(bool initiated, unsigned int type, int af);
uint64_t rep_hist_get_conn_rejected(unsigned int type, int af);

void rep_hist_note_exit_stream(unsigned int cmd);
uint64_t rep_hist_get_exit_stream_seen(unsigned int cmd);

void rep_hist_buffer_stats_init(time_t now);
void rep_hist_buffer_stats_add_circ(circuit_t *circ,
                                    time_t end_of_interval);
time_t rep_hist_buffer_stats_write(time_t now);
void rep_hist_buffer_stats_term(void);
void rep_hist_add_buffer_stats(double mean_num_cells_in_queue,
     double mean_time_cells_in_queue, uint32_t processed_cells);
char *rep_hist_format_buffer_stats(time_t now);
void rep_hist_reset_buffer_stats(time_t now);

void rep_hist_desc_stats_init(time_t now);
void rep_hist_note_desc_served(const char * desc);
void rep_hist_desc_stats_term(void);
time_t rep_hist_desc_stats_write(time_t now);

void rep_hist_note_circuit_handshake_requested(uint16_t type);
void rep_hist_note_circuit_handshake_assigned(uint16_t type);
void rep_hist_note_circuit_handshake_dropped(uint16_t type);
void rep_hist_log_circuit_handshake_stats(time_t now);

MOCK_DECL(int, rep_hist_get_circuit_handshake_requested, (uint16_t type));
MOCK_DECL(int, rep_hist_get_circuit_handshake_assigned, (uint16_t type));

MOCK_DECL(uint64_t, rep_hist_get_circuit_n_handshake_assigned,
          (uint16_t type));
MOCK_DECL(uint64_t, rep_hist_get_circuit_n_handshake_dropped,
          (uint16_t type));

void rep_hist_hs_stats_init(time_t now);
void rep_hist_hs_stats_term(void);
time_t rep_hist_hs_stats_write(time_t now, bool is_v3);

void rep_hist_seen_new_rp_cell(bool is_v2);

char *rep_hist_get_hs_v3_stats_string(void);
void rep_hist_hsdir_stored_maybe_new_v3_onion(const uint8_t *blinded_key);

void rep_hist_free_all(void);

void rep_hist_note_negotiated_link_proto(unsigned link_proto,
                                         int started_here);
void rep_hist_log_link_protocol_counts(void);

uint64_t rep_hist_get_n_dns_error(int type, uint8_t error);
uint64_t rep_hist_get_n_dns_request(int type);
void rep_hist_note_dns_request(int type);
void rep_hist_note_dns_error(int type, uint8_t error);

void rep_hist_consensus_has_changed(const networkstatus_t *ns);

/** We combine ntor and ntorv3 stats, so we have 3 stat types:
 * tap, fast, and ntor. The max type is ntor (2) */
#define MAX_ONION_STAT_TYPE   ONION_HANDSHAKE_TYPE_NTOR

extern uint64_t rephist_total_alloc;
extern uint32_t rephist_total_num;
#ifdef TOR_UNIT_TESTS
extern int onion_handshakes_requested[MAX_ONION_STAT_TYPE+1];
extern int onion_handshakes_assigned[MAX_ONION_STAT_TYPE+1];
#endif

#ifdef REPHIST_PRIVATE
/** Carries the various hidden service statistics, and any other
 *  information needed. */
typedef struct hs_v2_stats_t {
  /** How many v2 relay cells have we seen as rendezvous points? */
  uint64_t rp_v2_relay_cells_seen;
} hs_v2_stats_t;

/** Structure that contains the various statistics we keep about v3
 *  services.
 *
 *  Because of the time period logic of v3 services, v3 statistics are more
 *  sensitive to time than v2 stats. For this reason, we collect v3
 *  statistics strictly from 12:00UTC to 12:00UTC as dictated by
 *  'start_of_hs_v3_stats_interval'.
 **/
typedef struct hs_v3_stats_t {
  /** How many v3 relay cells have we seen as a rendezvous point? */
  uint64_t rp_v3_relay_cells_seen;

  /* The number of unique v3 onion descriptors (actually, unique v3 blind keys)
   * we've seen during the measurement period */
  digest256map_t *v3_onions_seen_this_period;
} hs_v3_stats_t;

MOCK_DECL(STATIC bool, should_collect_v3_stats,(void));

STATIC char *rep_hist_format_hs_stats(time_t now, bool is_v3);
#endif /* defined(REPHIST_PRIVATE) */

/**
 * Represents the type of a cell for padding accounting
 */
typedef enum padding_type_t {
    /** A RELAY_DROP cell */
    PADDING_TYPE_DROP,
    /** A CELL_PADDING cell */
    PADDING_TYPE_CELL,
    /** Total counts of padding and non-padding together */
    PADDING_TYPE_TOTAL,
    /** Total cell counts for all padding-enabled channels */
    PADDING_TYPE_ENABLED_TOTAL,
    /** CELL_PADDING counts for all padding-enabled channels */
    PADDING_TYPE_ENABLED_CELL
} padding_type_t;

/** The amount of time over which the padding cell counts were counted */
#define REPHIST_CELL_PADDING_COUNTS_INTERVAL (24*60*60)
void rep_hist_padding_count_read(padding_type_t type);
void rep_hist_padding_count_write(padding_type_t type);
char *rep_hist_get_padding_count_lines(void);
void rep_hist_reset_padding_counts(void);
void rep_hist_prep_published_padding_counts(time_t now);
void rep_hist_padding_count_timers(uint64_t num_timers);

/**
 * Represents the various types of overload we keep track of and expose in our
 * extra-info descriptor.
*/
typedef enum {
  /* A general overload -- can have many different causes. */
  OVERLOAD_GENERAL,
  /* We went over our configured read rate/burst bandwidth limit */
  OVERLOAD_READ,
  /* We went over our configured write rate/burst bandwidth limit */
  OVERLOAD_WRITE,
  /* We exhausted the file descriptors in this system */
  OVERLOAD_FD_EXHAUSTED,
} overload_type_t;

void rep_hist_note_overload(overload_type_t overload);
char *rep_hist_get_overload_general_line(void);
char *rep_hist_get_overload_stats_lines(void);

void rep_hist_note_tcp_exhaustion(void);
uint64_t rep_hist_get_n_tcp_exhaustion(void);

uint64_t rep_hist_get_n_read_limit_reached(void);
uint64_t rep_hist_get_n_write_limit_reached(void);

#ifdef TOR_UNIT_TESTS
struct hs_v2_stats_t;
const struct hs_v2_stats_t *rep_hist_get_hs_v2_stats(void);
struct hs_v3_stats_t;
const struct hs_v3_stats_t *rep_hist_get_hs_v3_stats(void);
#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TOR_REPHIST_H) */
