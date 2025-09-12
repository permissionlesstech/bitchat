/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_DISPATCH_H
#define TOR_DISPATCH_H

#include "lib/dispatch/msgtypes.h"

/**
 * \file dispatch.h
 * \brief Low-level APIs for message-passing system.
 *
 * This module implements message dispatch based on a set of short integer
 * identifiers.  For a higher-level interface, see pubsub.h.
 *
 * Each message is represented as a generic msg_t object, and is discriminated
 * by its message_id_t.  Messages are delivered by a dispatch_t object, which
 * delivers each message to its recipients by a configured "channel".
 *
 * A "channel" is a means of delivering messages.  Every message_id_t must
 * be associated with exactly one channel, identified by channel_id_t.
 * When a channel receives messages, a callback is invoked to either process
 * the messages immediately, or to cause them to be processed later.
 *
 * Every message_id_t has zero or more associated receiver functions set up in
 * the dispatch_t object.  Once the dispatch_t object is created, receivers
 * can be enabled or disabled [TODO], but not added or removed.
 *
 * Every message_id_t has an associated datatype, identified by a
 * msg_type_id_t.  These datatypes can be associated with functions to
 * (for example) free them, or format them for debugging.
 *
 * To setup a dispatch_t object, first create a dispatch_cfg_t object, and
 * configure messages with their types, channels, and receivers.  Then, use
 * dispatch_new() with that dispatch_cfg_t to create the dispatch_t object.
 *
 * (We use a two-phase construction procedure here to enable better static
 * reasoning about publish/subscribe relationships.)
 *
 * Once you have a dispatch_t, you can queue messages on it with
 * dispatch_send*(), and cause those messages to be delivered with
 * dispatch_flush().
 **/

/**
 * A "dispatcher" is the highest-level object; it handles making sure that
 * messages are received and delivered properly.  Only the mainloop
 * should handle this type directly.
 */
typedef struct dispatch_t dispatch_t;

struct dispatch_cfg_t;

dispatch_t *dispatch_new(const struct dispatch_cfg_t *cfg);

/**
 * Free a dispatcher.  Tor does this at exit.
 */
#define dispatch_free(d) \
  FREE_AND_NULL(dispatch_t, dispatch_free_, (d))

void dispatch_free_(dispatch_t *);

int dispatch_send(dispatch_t *d,
                  subsys_id_t sender,
                  channel_id_t channel,
                  message_id_t msg,
                  msg_type_id_t type,
                  msg_aux_data_t auxdata);

int dispatch_send_msg(dispatch_t *d, msg_t *m);

int dispatch_send_msg_unchecked(dispatch_t *d, msg_t *m);

/* Flush up to <b>max_msgs</b> currently pending messages from the
 * dispatcher.  Messages that are not pending when this function are
 * called, are not flushed by this call.  Return 0 on success, -1 on
 * unrecoverable error.
 */
int dispatch_flush(dispatch_t *, channel_id_t chan, int max_msgs);

/**
 * Function callback type used to alert some other module when a channel's
 * queue changes from empty to nonempty.
 *
 * Ex 1: To cause messages to be processed immediately on-stack, this callback
 * should invoke dispatch_flush() directly.
 *
 * Ex 2: To cause messages to be processed very soon, from the event queue,
 * this callback should schedule an event callback to run dispatch_flush().
 *
 * Ex 3: To cause messages to be processed periodically, this function should
 * do nothing, and a periodic event should invoke dispatch_flush().
 **/
typedef void (*dispatch_alertfn_t)(struct dispatch_t *,
                                   channel_id_t, void *);

int dispatch_set_alert_fn(dispatch_t *d, channel_id_t chan,
                          dispatch_alertfn_t fn, void *userdata);

#define dispatch_free_msg(d,msg)                                \
  STMT_BEGIN {                                                  \
    msg_t **msg_tmp_ptr__ = &(msg);                             \
    dispatch_free_msg_((d), *msg_tmp_ptr__);                    \
    *msg_tmp_ptr__= NULL;                                       \
  } STMT_END
void dispatch_free_msg_(const dispatch_t *d, msg_t *msg);

char *dispatch_fmt_msg_data(const dispatch_t *d, const msg_t *msg);

#endif /* !defined(TOR_DISPATCH_H) */
