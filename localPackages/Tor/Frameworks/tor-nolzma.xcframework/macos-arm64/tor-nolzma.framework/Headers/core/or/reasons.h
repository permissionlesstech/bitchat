/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file reasons.h
 * \brief Header file for reasons.c.
 **/

#ifndef TOR_REASONS_H
#define TOR_REASONS_H

#include "lib/net/socks5_status.h"
enum bandwidth_weight_rule_t;

const char *stream_end_reason_to_control_string(int reason);
const char *stream_end_reason_to_string(int reason);
socks5_reply_status_t stream_end_reason_to_socks5_response(int reason);
uint8_t errno_to_stream_end_reason(int e);

const char *orconn_end_reason_to_control_string(int r);
int tls_error_to_orconn_end_reason(int e);
int errno_to_orconn_end_reason(int e);

const char *circuit_end_reason_to_control_string(int reason);
const char *socks4_response_code_to_string(uint8_t code);
const char *socks5_response_code_to_string(uint8_t code);

const char *bandwidth_weight_rule_to_string(enum bandwidth_weight_rule_t rule);
const char *end_reason_to_http_connect_response_line(int endreason);

#endif /* !defined(TOR_REASONS_H) */
