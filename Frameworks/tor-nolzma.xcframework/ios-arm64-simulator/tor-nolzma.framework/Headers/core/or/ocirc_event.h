/* Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file ocirc_event.h
 * \brief Header file for ocirc_event.c
 **/

#ifndef TOR_OCIRC_EVENT_H
#define TOR_OCIRC_EVENT_H

#include <stdbool.h>

#include "lib/cc/torint.h"
#include "lib/pubsub/pubsub.h"

/** Used to indicate the type of a circuit event passed to the controller.
 * The various types are defined in control-spec.txt */
typedef enum circuit_status_event_t {
  CIRC_EVENT_LAUNCHED = 0,
  CIRC_EVENT_BUILT    = 1,
  CIRC_EVENT_EXTENDED = 2,
  CIRC_EVENT_FAILED   = 3,
  CIRC_EVENT_CLOSED   = 4,
} circuit_status_event_t;

/** Message for origin circuit state update */
typedef struct ocirc_state_msg_t {
  uint32_t gid;       /**< global ID (only origin circuits have them) */
  int state;          /**< new circuit state */
  bool onehop;        /**< one-hop circuit? */
} ocirc_state_msg_t;

DECLARE_MESSAGE(ocirc_state, ocirc_state, ocirc_state_msg_t *);

/**
 * Message when a channel gets associated to a circuit.
 *
 * This doesn't always correspond to something in circuitbuild.c
 * setting the n_chan field in the circuit.  For some reason, if
 * circuit_handle_first_hop() launches a new circuit, it doesn't set
 * the n_chan field.
 */
typedef struct ocirc_chan_msg_t {
  uint32_t gid;                 /**< global ID */
  uint64_t chan;                /**< channel ID */
  bool onehop;                  /**< one-hop circuit? */
} ocirc_chan_msg_t;

DECLARE_MESSAGE(ocirc_chan, ocirc_chan, ocirc_chan_msg_t *);

/**
 * Message for origin circuit status event
 *
 * This contains information that ends up in CIRC control protocol events.
 */
typedef struct ocirc_cevent_msg_t {
  uint32_t gid;                 /**< global ID */
  int evtype;                   /**< event type */
  int reason;                   /**< reason */
  bool onehop;                  /**< one-hop circuit? */
} ocirc_cevent_msg_t;

DECLARE_MESSAGE(ocirc_cevent, ocirc_cevent, ocirc_cevent_msg_t *);

#ifdef OCIRC_EVENT_PRIVATE
void ocirc_state_publish(ocirc_state_msg_t *msg);
void ocirc_chan_publish(ocirc_chan_msg_t *msg);
void ocirc_cevent_publish(ocirc_cevent_msg_t *msg);
#endif

#endif /* !defined(TOR_OCIRC_EVENT_H) */
