/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuituse.h
 * \brief Header file for circuituse.c.
 **/

#ifndef TOR_CIRCUITUSE_H
#define TOR_CIRCUITUSE_H

void circuit_expire_building(void);
void circuit_expire_waiting_for_better_guard(void);
void circuit_remove_handled_ports(smartlist_t *needed_ports);
int circuit_stream_is_being_handled(entry_connection_t *conn, uint16_t port,
                                    int min);
void circuit_log_ancient_one_hop_circuits(int age);
#if 0
int circuit_conforms_to_options(const origin_circuit_t *circ,
                                const or_options_t *options);
#endif
void circuit_build_needed_circs(time_t now);
void circuit_expire_old_circs_as_needed(time_t now);
void circuit_detach_stream(circuit_t *circ, edge_connection_t *conn);

void circuit_expire_old_circuits_serverside(time_t now);

void reset_bandwidth_test(void);
int circuit_enough_testing_circs(void);

void circuit_has_opened(origin_circuit_t *circ);
void circuit_try_attaching_streams(origin_circuit_t *circ);
void circuit_build_failed(origin_circuit_t *circ);

/** Flag to set when a circuit should have only a single hop. */
#define CIRCLAUNCH_ONEHOP_TUNNEL    (1<<0)
/** Flag to set when a circuit needs to be built of high-uptime nodes */
#define CIRCLAUNCH_NEED_UPTIME      (1<<1)
/** Flag to set when a circuit needs to be built of high-capacity nodes */
#define CIRCLAUNCH_NEED_CAPACITY    (1<<2)
/** Flag to set when the last hop of a circuit doesn't need to be an
 * exit node. */
#define CIRCLAUNCH_IS_INTERNAL      (1<<3)
/** Flag to set when we are trying to launch a self-testing circuit to our
 *  IPv6 ORPort. We need to apply some additional filters on the second-last
 *  node in the circuit. (We are both the client and the last node in the
 *  circuit.) */
#define CIRCLAUNCH_IS_IPV6_SELFTEST (1<<5)
/** Flag to set when a circuit needs the exit to support conflux. */
#define CIRCLAUNCH_NEED_CONFLUX     (1<<6)

origin_circuit_t *circuit_launch_by_extend_info(uint8_t purpose,
                                                extend_info_t *info,
                                                int flags);
origin_circuit_t *circuit_launch(uint8_t purpose, int flags);
void circuit_reset_failure_count(int timeout);
int connection_ap_handshake_attach_chosen_circuit(entry_connection_t *conn,
                                                  origin_circuit_t *circ,
                                                  crypt_path_t *cpath);
int connection_ap_handshake_attach_circuit(entry_connection_t *conn);

void circuit_change_purpose(circuit_t *circ, uint8_t new_purpose);

int hostname_in_track_host_exits(const or_options_t *options,
                                 const char *address);
void mark_circuit_unusable_for_new_conns(origin_circuit_t *circ);

int circuit_purpose_is_hidden_service(uint8_t);

/* Series of helper functions for hidden services. */
bool circuit_purpose_is_hs_client(const uint8_t purpose);
bool circuit_purpose_is_hs_service(const uint8_t purpose);
bool circuit_purpose_is_hs_vanguards(const uint8_t purpose);

bool circuit_is_hs_v3(const circuit_t *circ);
int circuit_is_acceptable(const origin_circuit_t *origin_circ,
                          const entry_connection_t *conn,
                          int must_be_open, uint8_t purpose,
                          int need_uptime, int need_internal,
                          time_t now);

int circuit_should_use_vanguards(uint8_t);
void circuit_sent_valid_data(origin_circuit_t *circ, uint16_t relay_body_len);
void circuit_read_valid_data(origin_circuit_t *circ, uint16_t relay_body_len);

#ifdef TOR_UNIT_TESTS
/* Used only by circuituse.c and test_circuituse.c */

STATIC int circuit_is_available_for_use(const circuit_t *circ);

STATIC int needs_exit_circuits(time_t now,
                               int *port_needs_uptime,
                               int *port_needs_capacity);
STATIC int needs_hs_server_circuits(time_t now,
                                    int num_uptime_internal);

STATIC int needs_hs_client_circuits(time_t now,
                                    int *needs_uptime,
                                    int *needs_capacity,
                                    int num_internal,
                                    int num_uptime_internal);

STATIC int needs_circuits_for_build(int num);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TOR_CIRCUITUSE_H) */

