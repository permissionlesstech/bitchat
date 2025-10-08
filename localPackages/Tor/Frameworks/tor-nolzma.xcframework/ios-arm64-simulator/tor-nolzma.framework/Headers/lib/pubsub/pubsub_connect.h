/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pubsub_connect.h
 * @brief Header for functions that add relationships to a pubsub builder.
 *
 * These functions are used by modules that need to add publication and
 * subscription requests.  Most users will want to call these functions
 * indirectly, via the macros in pubsub_macros.h.
 **/

#ifndef TOR_PUBSUB_CONNECT_H
#define TOR_PUBSUB_CONNECT_H

#include "lib/dispatch/msgtypes.h"

struct pub_binding_t;
/**
 * A "dispatch connector" is a view of the dispatcher that a subsystem
 * uses while initializing itself.  It is specific to the subsystem, and
 * ensures that each subsystem doesn't need to identify itself
 * repeatedly while registering its messages.
 **/
typedef struct pubsub_connector_t pubsub_connector_t;

int pubsub_add_pub_(struct pubsub_connector_t *con,
                    struct pub_binding_t *out,
                    channel_id_t channel,
                    message_id_t msg,
                    msg_type_id_t type,
                    unsigned flags,
                    const char *file,
                    unsigned line);

int pubsub_add_sub_(struct pubsub_connector_t *con,
                    recv_fn_t recv_fn,
                    channel_id_t channel,
                    message_id_t msg,
                    msg_type_id_t type,
                    unsigned flags,
                    const char *file,
                    unsigned line);

int pubsub_connector_register_type_(struct pubsub_connector_t *,
                                    msg_type_id_t,
                                    dispatch_typefns_t *,
                                    const char *file,
                                    unsigned line);

#endif /* !defined(TOR_PUBSUB_CONNECT_H) */
