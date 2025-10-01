/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file congestion_control_flow.h
 * \brief APIs for stream flow control on congestion controlled circuits.
 **/

#ifndef TOR_CONGESTION_CONTROL_FLOW_H
#define TOR_CONGESTION_CONTROL_FLOW_H

#include "core/or/crypt_path_st.h"
#include "core/or/circuit_st.h"
#include "core/or/edge_connection_st.h"

void flow_control_new_consensus_params(const struct networkstatus_t *);

bool circuit_process_stream_xoff(edge_connection_t *conn,
                                 const crypt_path_t *layer_hint,
                                 const cell_t *cell);
bool circuit_process_stream_xon(edge_connection_t *conn,
                                const crypt_path_t *layer_hint,
                                const cell_t *cell);

int flow_control_decide_xoff(edge_connection_t *stream);
void flow_control_decide_xon(edge_connection_t *stream, size_t n_written);

void flow_control_note_sent_data(edge_connection_t *stream, size_t len);

bool edge_uses_flow_control(const edge_connection_t *stream);

bool conn_uses_flow_control(connection_t *stream);

/** Metricsport externs */
extern uint64_t cc_stats_flow_num_xoff_sent;
extern uint64_t cc_stats_flow_num_xon_sent;
extern double cc_stats_flow_xoff_outbuf_ma;
extern double cc_stats_flow_xon_outbuf_ma;

/* Private section starts. */
#ifdef TOR_CONGESTION_CONTROL_FLOW_PRIVATE

/*
 * Unit tests declaractions.
 */
#ifdef TOR_UNIT_TESTS

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(TOR_CONGESTION_CONTROL_FLOW_PRIVATE) */

#endif /* !defined(TOR_CONGESTION_CONTROL_FLOW_H) */
