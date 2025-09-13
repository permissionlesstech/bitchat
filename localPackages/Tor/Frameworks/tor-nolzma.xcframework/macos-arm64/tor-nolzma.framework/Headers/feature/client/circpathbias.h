/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitbuild.h
 * \brief Header file for circuitbuild.c.
 **/

#ifndef TOR_CIRCPATHBIAS_H
#define TOR_CIRCPATHBIAS_H

double pathbias_get_extreme_rate(const or_options_t *options);
double pathbias_get_extreme_use_rate(const or_options_t *options);
int pathbias_get_dropguards(const or_options_t *options);
void pathbias_count_timeout(origin_circuit_t *circ);
void pathbias_count_build_success(origin_circuit_t *circ);
int pathbias_count_build_attempt(origin_circuit_t *circ);
int pathbias_check_close(origin_circuit_t *circ, int reason);
int pathbias_check_probe_response(circuit_t *circ, const cell_t *cell);
void pathbias_count_valid_cells(circuit_t *circ, const cell_t *cell);
void pathbias_count_use_attempt(origin_circuit_t *circ);
void pathbias_mark_use_success(origin_circuit_t *circ);
void pathbias_mark_use_rollback(origin_circuit_t *circ);
const char *pathbias_state_to_string(enum path_state_t state);

#endif /* !defined(TOR_CIRCPATHBIAS_H) */
