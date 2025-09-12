/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file mainloop.h
 * \brief Header file for mainloop.c.
 **/

#ifndef TOR_MAINLOOP_H
#define TOR_MAINLOOP_H

int have_completed_a_circuit(void);
void note_that_we_completed_a_circuit(void);
void note_that_we_maybe_cant_complete_circuits(void);

int connection_add_impl(connection_t *conn, int is_connecting);
#define connection_add(conn) connection_add_impl((conn), 0)
#define connection_add_connecting(conn) connection_add_impl((conn), 1)
int connection_remove(connection_t *conn);
void connection_unregister_events(connection_t *conn);
int connection_in_array(connection_t *conn);
void add_connection_to_closeable_list(connection_t *conn);
int connection_is_on_closeable_list(connection_t *conn);

MOCK_DECL(smartlist_t *, get_connection_array, (void));
MOCK_DECL(uint64_t,get_bytes_read,(void));
MOCK_DECL(uint64_t,get_bytes_written,(void));
void stats_increment_bytes_read_and_written(uint64_t r, uint64_t w);

/** Bitmask for events that we can turn on and off with
 * connection_watch_events. */
typedef enum watchable_events {
  /* Yes, it is intentional that these match Libevent's EV_READ and EV_WRITE */
  READ_EVENT=0x02, /**< We want to know when a connection is readable */
  WRITE_EVENT=0x04 /**< We want to know when a connection is writable */
} watchable_events_t;
void connection_watch_events(connection_t *conn, watchable_events_t events);
int connection_is_reading(const connection_t *conn);
MOCK_DECL(void,connection_stop_reading,(connection_t *conn));
MOCK_DECL(void,connection_start_reading,(connection_t *conn));

int connection_is_writing(connection_t *conn);
MOCK_DECL(void,connection_stop_writing,(connection_t *conn));
MOCK_DECL(void,connection_start_writing,(connection_t *conn));

void tor_shutdown_event_loop_and_exit(int exitcode);
int tor_event_loop_shutdown_is_pending(void);

void connection_stop_reading_from_linked_conn(connection_t *conn);

MOCK_DECL(int, connection_count_moribund, (void));

void directory_all_unreachable(time_t now);
void directory_info_has_arrived(time_t now, int from_cache, int suppress_logs);

void ip_address_changed(int on_client_conn);
void dns_servers_relaunch_checks(void);
void reset_all_main_loop_timers(void);
void reschedule_directory_downloads(void);
void reschedule_or_state_save(void);
void mainloop_schedule_postloop_cleanup(void);
void rescan_periodic_events(const or_options_t *options);
MOCK_DECL(void, schedule_rescan_periodic_events,(void));

void update_current_time(time_t now);

MOCK_DECL(long,get_uptime,(void));
MOCK_DECL(void,reset_uptime,(void));

unsigned get_signewnym_epoch(void);

int do_main_loop(void);

void reset_main_loop_counters(void);
uint64_t get_main_loop_success_count(void);
uint64_t get_main_loop_error_count(void);
uint64_t get_main_loop_idle_count(void);

void periodic_events_on_new_options(const or_options_t *options);

void do_signewnym(time_t);
time_t get_last_signewnym_time(void);

void mainloop_schedule_shutdown(int delay_sec);

void tor_init_connection_lists(void);
void initialize_mainloop_events(void);
void initialize_periodic_events(void);
void tor_mainloop_free_all(void);

struct token_bucket_rw_t;

extern time_t time_of_process_start;
extern struct token_bucket_rw_t global_bucket;
extern struct token_bucket_rw_t global_relayed_bucket;

#ifdef MAINLOOP_PRIVATE
STATIC int run_main_loop_until_done(void);
STATIC void close_closeable_connections(void);
STATIC void teardown_periodic_events(void);
STATIC int get_my_roles(const or_options_t *);
STATIC int check_network_participation_callback(time_t now,
                                                const or_options_t *options);

#ifdef TOR_UNIT_TESTS
extern smartlist_t *connection_array;

/* We need the periodic_event_item_t definition. */
#include "core/mainloop/periodic.h"
extern periodic_event_item_t mainloop_periodic_events[];
#endif /* defined(TOR_UNIT_TESTS) */
#endif /* defined(MAINLOOP_PRIVATE) */

#endif /* !defined(TOR_MAINLOOP_H) */
