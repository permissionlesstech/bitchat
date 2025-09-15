/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dispatch_st.h
 *
 * \brief private structures used for the dispatcher module
 */

#ifndef TOR_DISPATCH_ST_H
#define TOR_DISPATCH_ST_H

#ifdef DISPATCH_PRIVATE

#include "lib/container/smartlist.h"

/**
 * Information about the recipient of a message.
 **/
typedef struct dispatch_rcv_t {
  /** The subsystem receiving a message. */
  subsys_id_t sys;
  /** True iff this recipient is enabled. */
  bool enabled;
  /** The function that will handle the message. */
  recv_fn_t fn;
} dispatch_rcv_t;

/**
 * Information used by a dispatcher to handle and dispatch a single message
 * ID.  It maps that message ID to its type, channel, and list of receiver
 * functions.
 *
 * This structure is used when the dispatcher is running.
 **/
typedef struct dtbl_entry_t {
  /** The number of enabled non-stub subscribers for this message.
   *
   * Note that for now, this will be the same as <b>n_fns</b>, since there is
   * no way to turn these subscribers on an off yet. */
  uint16_t n_enabled;
  /** The channel that handles this message. */
  channel_id_t channel;
  /** The associated C type for this message. */
  msg_type_id_t type;
  /**
   * The number of functions pointers for subscribers that receive this
   * message, in rcv. */
  uint16_t n_fns;
  /**
   * The recipients for this message.
   */
  dispatch_rcv_t rcv[FLEXIBLE_ARRAY_MEMBER];
} dtbl_entry_t;

/**
 * A queue of messages for a given channel, used by a live dispatcher.
 */
typedef struct dqueue_t {
  /** The queue of messages itself. */
  TOR_SIMPLEQ_HEAD( , msg_t) queue;
  /** A function to be called when the queue becomes nonempty. */
  dispatch_alertfn_t alert_fn;
  /** An argument for the alert_fn. */
  void *alert_fn_arg;
} dqueue_t ;

/**
 * A single dispatcher for cross-module messages.
 */
struct dispatch_t {
  /**
   * The length of <b>table</b>: the number of message IDs that this
   * dispatcher can handle.
   */
  size_t n_msgs;
  /**
   * The length of <b>queues</b>: the number of channels that this dispatcher
   * has configured.
   */
  size_t n_queues;
  /**
   * The length of <b>typefns</b>: the number of C type IDs that this
   * dispatcher has configured.
   */
  size_t n_types;
  /**
   * An array of message queues, indexed by channel ID.
   */
  dqueue_t *queues;
  /**
   * An array of entries about how to handle particular message types, indexed
   * by message ID.
   */
  dtbl_entry_t **table;
  /**
   * An array of function tables for manipulating types, index by message
   * type ID.
   **/
  dispatch_typefns_t *typefns;
};

#endif /* defined(DISPATCH_PRIVATE) */

#endif /* !defined(TOR_DISPATCH_ST_H) */
