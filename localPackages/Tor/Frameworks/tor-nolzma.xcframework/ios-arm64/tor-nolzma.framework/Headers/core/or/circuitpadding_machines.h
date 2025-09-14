/* Copyright (c) 2018 The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitpadding_machines.h
 * \brief Header file for circuitpadding_machines.c.
 **/

#ifndef TOR_CIRCUITPADDING_MACHINES_H
#define TOR_CIRCUITPADDING_MACHINES_H

void circpad_machine_relay_hide_intro_circuits(smartlist_t *machines_sl);
void circpad_machine_client_hide_intro_circuits(smartlist_t *machines_sl);
void circpad_machine_relay_hide_rend_circuits(smartlist_t *machines_sl);
void circpad_machine_client_hide_rend_circuits(smartlist_t *machines_sl);

#ifdef CIRCUITPADDING_MACHINES_PRIVATE

/** State of the padding machines that actually sends padding */
#define CIRCPAD_STATE_OBFUSCATE_CIRC_SETUP CIRCPAD_STATE_BURST

/** Constants defining the amount of padding that a machine will send to hide
 *  HS circuits. The actual value is sampled uniformly random between the
 *  min/max values.
 */

/** Minimum number of relay-side padding cells to be sent by this machine */
#define INTRO_MACHINE_MINIMUM_PADDING 7
/** Maximum number of relay-side padding cells to be sent by this machine.
 *  The actual value will be sampled between the min and max.*/
#define INTRO_MACHINE_MAXIMUM_PADDING 10

#endif /* defined(CIRCUITPADDING_MACHINES_PRIVATE) */

#endif /* !defined(TOR_CIRCUITPADDING_MACHINES_H) */
