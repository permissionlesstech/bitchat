/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pubsub_publish.h
 * @brief Header for pubsub_publish.c
 **/

#ifndef TOR_PUBSUB_PUBLISH_H
#define TOR_PUBSUB_PUBLISH_H

#include "lib/dispatch/msgtypes.h"
struct pub_binding_t;

int pubsub_pub_(const struct pub_binding_t *pub, msg_aux_data_t auxdata);

#endif /* !defined(TOR_PUBSUB_PUBLISH_H) */
