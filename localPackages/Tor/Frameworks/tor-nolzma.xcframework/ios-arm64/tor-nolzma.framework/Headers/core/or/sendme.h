/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file sendme.h
 * \brief Header file for sendme.c.
 **/

#ifndef TOR_SENDME_H
#define TOR_SENDME_H

#include "core/or/edge_connection_st.h"
#include "core/or/crypt_path_st.h"
#include "core/or/circuit_st.h"

/* Sending SENDME cell. */
void sendme_connection_edge_consider_sending(edge_connection_t *edge_conn);
void sendme_circuit_consider_sending(circuit_t *circ,
                                     crypt_path_t *layer_hint);

/* Processing SENDME cell. */
int sendme_process_circuit_level(crypt_path_t *layer_hint,
                                 circuit_t *circ, const uint8_t *cell_payload,
                                 uint16_t cell_payload_len);
int sendme_process_circuit_level_impl(crypt_path_t *, circuit_t *);
int sendme_process_stream_level(edge_connection_t *conn, circuit_t *circ,
                                uint16_t cell_body_len);

/* Update deliver window functions. */
int sendme_stream_data_received(edge_connection_t *conn);
int sendme_circuit_data_received(circuit_t *circ, crypt_path_t *layer_hint);

/* Update package window functions. */
int sendme_note_circuit_data_packaged(circuit_t *circ,
                                      crypt_path_t *layer_hint);
int sendme_note_stream_data_packaged(edge_connection_t *conn, size_t len);

/* Record cell digest on circuit. */
void sendme_record_cell_digest_on_circ(circuit_t *circ, crypt_path_t *cpath);
/* Record cell digest as the SENDME digest. */
void sendme_record_received_cell_digest(circuit_t *circ, crypt_path_t *cpath);
void sendme_record_sending_cell_digest(circuit_t *circ, crypt_path_t *cpath);

/* Private section starts. */
#ifdef SENDME_PRIVATE

/* The maximum supported version. Above that value, the cell can't be
 * recognized as a valid SENDME. */
#define SENDME_MAX_SUPPORTED_VERSION 1

/* The cell version constants for when emitting a cell. */
#define SENDME_EMIT_MIN_VERSION_DEFAULT 1
#define SENDME_EMIT_MIN_VERSION_MIN 0
#define SENDME_EMIT_MIN_VERSION_MAX UINT8_MAX

/* The cell version constants for when accepting a cell. */
#define SENDME_ACCEPT_MIN_VERSION_DEFAULT 0
#define SENDME_ACCEPT_MIN_VERSION_MIN 0
#define SENDME_ACCEPT_MIN_VERSION_MAX UINT8_MAX

/*
 * Unit tests declaractions.
 */
#ifdef TOR_UNIT_TESTS

STATIC int get_emit_min_version(void);
STATIC int get_accept_min_version(void);

STATIC bool cell_version_can_be_handled(uint8_t cell_version);

STATIC ssize_t build_cell_payload_v1(const uint8_t *cell_digest,
                                     uint8_t *payload);
STATIC bool sendme_is_valid(const circuit_t *circ,
                            const uint8_t *cell_payload,
                            size_t cell_payload_len);
STATIC bool circuit_sendme_cell_is_next(int deliver_window,
                                        int sendme_inc);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(SENDME_PRIVATE) */

#endif /* !defined(TOR_SENDME_H) */
