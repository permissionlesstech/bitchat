/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pub_binding_st.h
 * @brief Declaration of pub_binding_t.
 *
 * This is an internal type for the pubsub implementation.
 */

#ifndef TOR_PUB_BINDING_ST_H
#define TOR_PUB_BINDING_ST_H

#include "lib/dispatch/msgtypes.h"
struct dispatch_t;

/**
 * A pub_binding_t is an opaque object that subsystems use to publish
 * messages.  The DISPATCH_ADD_PUB*() macros set it up.
 **/
typedef struct pub_binding_t {
  /**
   * A pointer to a configured dispatch_t object.  This is filled in
   * when the dispatch_t is finally constructed.
   **/
  struct dispatch_t *dispatch_ptr;
  /**
   * A template for the msg_t fields that are filled in for this message.
   * This is copied into outgoing messages, ensuring that their fields are set
   * correctly.
   **/
  msg_t msg_template;
} pub_binding_t;

#endif /* !defined(TOR_PUB_BINDING_ST_H) */
