/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file msgtypes.h
 * \brief Types used for messages in the dispatcher code.
 **/

#ifndef TOR_DISPATCH_MSGTYPES_H
#define TOR_DISPATCH_MSGTYPES_H

#include <stdint.h>

#include "ext/tor_queue.h"

/**
 * These types are aliases for subsystems, channels, and message IDs.
 **/
typedef uint16_t subsys_id_t;
typedef uint16_t channel_id_t;
typedef uint16_t message_id_t;

/**
 * This identifies a C type that can be sent along with a message.
 **/
typedef uint16_t msg_type_id_t;

/**
 * An ID value returned for *_type_t when none exists.
 */
#define ERROR_ID 65535

/**
 * Auxiliary (untyped) data sent along with a message.
 *
 * We define this as a union of a pointer and a u64, so that the integer
 * types will have the same range across platforms.
 **/
typedef union {
  void *ptr;
  uint64_t u64;
} msg_aux_data_t;

/**
 * Structure of a received message.
 **/
typedef struct msg_t {
  TOR_SIMPLEQ_ENTRY(msg_t) next;
  subsys_id_t sender;
  channel_id_t channel;
  message_id_t msg;
  /** We could omit this field, since it is implicit in the message type, but
   * IMO let's leave it in for safety. */
  msg_type_id_t type;
  /** Untyped auxiliary data. You shouldn't have to mess with this
   * directly. */
  msg_aux_data_t aux_data__;
} msg_t;

/**
 * A function that a subscriber uses to receive a message.
 **/
typedef void (*recv_fn_t)(const msg_t *m);

/**
 * Table of functions to use for a given C type.  Any omitted (NULL) functions
 * will be treated as no-ops.
 **/
typedef struct dispatch_typefns_t {
  /** Release storage held for the auxiliary data of this type. */
  void (*free_fn)(msg_aux_data_t);
  /** Format and return a newly allocated string describing the contents
   * of this data element. */
  char *(*fmt_fn)(msg_aux_data_t);
} dispatch_typefns_t;

#endif /* !defined(TOR_DISPATCH_MSGTYPES_H) */
