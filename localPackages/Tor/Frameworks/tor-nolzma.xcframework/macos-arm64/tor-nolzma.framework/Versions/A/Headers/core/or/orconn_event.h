/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file orconn_event.h
 * \brief Header file for orconn_event.c
 *
 * The OR_CONN_STATE_* symbols are here to make it easier for
 * subscribers to make decisions based on the messages that they
 * receive.
 **/

#ifndef TOR_ORCONN_EVENT_H
#define TOR_ORCONN_EVENT_H

#include "lib/pubsub/pubsub.h"

/**
 * @name States of OR connections
 *
 * These must be in a partial ordering such that usually no OR
 * connection will transition from a higher-numbered state to a
 * lower-numbered one.  Code such as bto_update_best() depends on this
 * ordering to determine the best state it's seen so far.
 * @{ */
#define OR_CONN_STATE_MIN_ 1
/** State for a connection to an OR: waiting for connect() to finish. */
#define OR_CONN_STATE_CONNECTING 1
/** State for a connection to an OR: waiting for proxy handshake to complete */
#define OR_CONN_STATE_PROXY_HANDSHAKING 2
/** State for an OR connection client: SSL is handshaking, not done
 * yet. */
#define OR_CONN_STATE_TLS_HANDSHAKING 3
/** State for a connection to an OR: We're doing a second SSL handshake for
 * renegotiation purposes. (V2 handshake only.) */
#define OR_CONN_STATE_TLS_CLIENT_RENEGOTIATING 4
/** State for a connection at an OR: We're waiting for the client to
 * renegotiate (to indicate a v2 handshake) or send a versions cell (to
 * indicate a v3 handshake) */
#define OR_CONN_STATE_TLS_SERVER_RENEGOTIATING 5
/** State for an OR connection: We're done with our SSL handshake, we've done
 * renegotiation, but we haven't yet negotiated link protocol versions and
 * sent a netinfo cell. */
#define OR_CONN_STATE_OR_HANDSHAKING_V2 6
/** State for an OR connection: We're done with our SSL handshake, but we
 * haven't yet negotiated link protocol versions, done a V3 handshake, and
 * sent a netinfo cell. */
#define OR_CONN_STATE_OR_HANDSHAKING_V3 7
/** State for an OR connection: Ready to send/receive cells. */
#define OR_CONN_STATE_OPEN 8
#define OR_CONN_STATE_MAX_ 8
/** @} */

/** Used to indicate the type of an OR connection event passed to the
 * controller.  The various types are defined in control-spec.txt */
typedef enum or_conn_status_event_t {
  OR_CONN_EVENT_LAUNCHED     = 0,
  OR_CONN_EVENT_CONNECTED    = 1,
  OR_CONN_EVENT_FAILED       = 2,
  OR_CONN_EVENT_CLOSED       = 3,
  OR_CONN_EVENT_NEW          = 4,
} or_conn_status_event_t;

/**
 * Message for orconn state update
 *
 * This contains information about internal state changes of
 * or_connection_t objects.  The chan and proxy_type fields are
 * additional information that a subscriber may need to make
 * decisions.
 **/
typedef struct orconn_state_msg_t {
  uint64_t gid;                 /**< connection's global ID */
  uint64_t chan;                /**< associated channel ID */
  int proxy_type;               /**< connection's proxy type */
  uint8_t state;                /**< new connection state */
} orconn_state_msg_t;

DECLARE_MESSAGE(orconn_state, orconn_state, orconn_state_msg_t *);

/**
 * Message for orconn status event
 *
 * This contains information that ends up in ORCONN control protocol
 * events.
 **/
typedef struct orconn_status_msg_t {
  uint64_t gid;                 /**< connection's global ID */
  int status;                   /**< or_conn_status_event_t */
  int reason;                   /**< reason */
} orconn_status_msg_t;

DECLARE_MESSAGE(orconn_status, orconn_status, orconn_status_msg_t *);

#ifdef ORCONN_EVENT_PRIVATE
void orconn_state_publish(orconn_state_msg_t *);
void orconn_status_publish(orconn_status_msg_t *);
#endif

#endif /* !defined(TOR_ORCONN_EVENT_H) */
