/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file rendcommon.h
 * \brief Header file for rendcommon.c.
 **/

#ifndef TOR_RENDCOMMON_H
#define TOR_RENDCOMMON_H

typedef enum rend_intro_point_failure_t {
  INTRO_POINT_FAILURE_GENERIC     = 0,
  INTRO_POINT_FAILURE_TIMEOUT     = 1,
  INTRO_POINT_FAILURE_UNREACHABLE = 2,
} rend_intro_point_failure_t;

void rend_process_relay_cell(circuit_t *circ, const crypt_path_t *layer_hint,
                             int command, size_t length,
                             const uint8_t *payload);

void assert_circ_anonymity_ok(const origin_circuit_t *circ,
                              const or_options_t *options);

#endif /* !defined(TOR_RENDCOMMON_H) */

