/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file connection_or.h
 * \brief Header file for connection_or.c.
 **/

#ifndef TOR_CONNECTION_OR_H
#define TOR_CONNECTION_OR_H

struct ed25519_public_key_t;
struct ed25519_keypair_t;

or_connection_t *TO_OR_CONN(connection_t *);
const or_connection_t *CONST_TO_OR_CONN(const connection_t *);

#include "core/or/orconn_event.h"

void connection_or_clear_identity(or_connection_t *conn);
void connection_or_clear_identity_map(void);
void clear_broken_connection_map(int disable);

void connection_or_block_renegotiation(or_connection_t *conn);
int connection_or_reached_eof(or_connection_t *conn);
int connection_or_process_inbuf(or_connection_t *conn);
ssize_t connection_or_num_cells_writeable(or_connection_t *conn);
int connection_or_flushed_some(or_connection_t *conn);
int connection_or_finished_flushing(or_connection_t *conn);
int connection_or_finished_connecting(or_connection_t *conn);
void connection_or_about_to_close(or_connection_t *conn);
int connection_or_digest_is_known_relay(const char *id_digest);
void connection_or_update_token_buckets(smartlist_t *conns,
                                        const or_options_t *options);

void connection_or_connect_failed(or_connection_t *conn,
                                  int reason, const char *msg);
void connection_or_notify_error(or_connection_t *conn,
                                int reason, const char *msg);
MOCK_DECL(or_connection_t *,
          connection_or_connect,
          (const tor_addr_t *addr, uint16_t port,
           const char *id_digest,
           const struct ed25519_public_key_t *ed_id,
           channel_tls_t *chan));

void connection_or_close_normally(or_connection_t *orconn, int flush);
MOCK_DECL(void,connection_or_close_for_error,
          (or_connection_t *orconn, int flush));

void connection_or_report_broken_states(int severity, int domain);

void connection_or_event_status(or_connection_t *conn,
                                or_conn_status_event_t tp, int reason);

MOCK_DECL(int,connection_tls_start_handshake,(or_connection_t *conn,
                                              int receiving));
int connection_tls_continue_handshake(or_connection_t *conn);
void connection_or_set_canonical(or_connection_t *or_conn,
                                 int is_canonical);

int connection_init_or_handshake_state(or_connection_t *conn,
                                       int started_here);
void connection_or_init_conn_from_address(or_connection_t *conn,
                                    const tor_addr_t *addr,
                                    uint16_t port,
                                    const char *rsa_id_digest,
                                    const struct ed25519_public_key_t *ed_id,
                                    int started_here);
int connection_or_client_learned_peer_id(or_connection_t *conn,
                              const uint8_t *rsa_peer_id,
                              const struct ed25519_public_key_t *ed_peer_id);
const struct ed25519_public_key_t *connection_or_get_alleged_ed25519_id(
                              const or_connection_t *conn);
time_t connection_or_client_used(or_connection_t *conn);
MOCK_DECL(int, connection_or_get_num_circuits, (or_connection_t *conn));
void or_handshake_state_free_(or_handshake_state_t *state);
#define or_handshake_state_free(state) \
  FREE_AND_NULL(or_handshake_state_t, or_handshake_state_free_, (state))
void or_handshake_state_record_cell(or_connection_t *conn,
                                    or_handshake_state_t *state,
                                    const cell_t *cell,
                                    int incoming);
void or_handshake_state_record_var_cell(or_connection_t *conn,
                                        or_handshake_state_t *state,
                                        const var_cell_t *cell,
                                        int incoming);

int connection_or_set_state_open(or_connection_t *conn);
void connection_or_write_cell_to_buf(const cell_t *cell,
                                     or_connection_t *conn);
MOCK_DECL(void,connection_or_write_var_cell_to_buf,(const var_cell_t *cell,
                                                   or_connection_t *conn));
int connection_or_send_versions(or_connection_t *conn, int v3_plus);
MOCK_DECL(int,connection_or_send_netinfo,(or_connection_t *conn));

int is_or_protocol_version_known(uint16_t version);

void cell_pack(packed_cell_t *dest, const cell_t *src, int wide_circ_ids);
int var_cell_pack_header(const var_cell_t *cell, char *hdr_out,
                         int wide_circ_ids);
var_cell_t *var_cell_new(uint16_t payload_len);
var_cell_t *var_cell_copy(const var_cell_t *src);
void var_cell_free_(var_cell_t *cell);
#define var_cell_free(cell) FREE_AND_NULL(var_cell_t, var_cell_free_, (cell))

/* DOCDOC */
#define MIN_LINK_PROTO_FOR_WIDE_CIRC_IDS 4
#define MIN_LINK_PROTO_FOR_CHANNEL_PADDING 5
#define MAX_LINK_PROTO MIN_LINK_PROTO_FOR_CHANNEL_PADDING

int connection_or_single_set_badness_(time_t now,
                                      or_connection_t *or_conn,
                                      int force);
void connection_or_group_set_badness_(smartlist_t *group, int force);

#ifdef CONNECTION_OR_PRIVATE
STATIC int should_connect_to_relay(const or_connection_t *or_conn);
STATIC void note_or_connect_failed(const or_connection_t *or_conn);
#endif /* defined(CONNECTION_OR_PRIVATE) */

/*
 * Call this when changing connection state, so notifications to the owning
 * channel can be handled.
 */
MOCK_DECL(void, connection_or_change_state,
          (or_connection_t *conn, uint8_t state));

#ifdef TOR_UNIT_TESTS
extern int testing__connection_or_pretend_TLSSECRET_is_supported;
#endif

#endif /* !defined(TOR_CONNECTION_OR_H) */
