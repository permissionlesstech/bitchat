/* Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file btrack_circuit.h
 * \brief Header file for btrack_circuit.c
 **/

#ifndef TOR_BTRACK_CIRCUIT_H
#define TOR_BTRACK_CIRCUIT_H

#include "lib/pubsub/pubsub.h"

int btrack_circ_init(void);
void btrack_circ_fini(void);
int btrack_circ_add_pubsub(pubsub_connector_t *);

#endif /* !defined(TOR_BTRACK_CIRCUIT_H) */
