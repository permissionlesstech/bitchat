/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file mainloop_pubsub.h
 * @brief Header for mainloop_pubsub.c
 **/

#ifndef TOR_MAINLOOP_PUBSUB_H
#define TOR_MAINLOOP_PUBSUB_H

struct pubsub_builder_t;

/**
 * Describe when and how messages are delivered on message channel.
 *
 * Every message channel must be associated with one of these strategies.
 **/
typedef enum {
   /**
    * Never deliver messages automatically.
    *
    * If a message channel uses this strategy, then no matter now many
    * messages are published on it, they are not delivered until something
    * manually calls dispatch_flush() for that channel
    **/
   DELIV_NEVER=0,
   /**
    * Deliver messages promptly, via the event loop.
    *
    * If a message channel uses this strategy, then publishing a messages
    * that channel activates an event that causes messages to be handled
    * later in the mainloop.  The messages will be processed at some point
    * very soon, delaying only for pending IO events and the like.
    *
    * Generally this is the best choice for a delivery strategy, since
    * it avoids stack explosion.
    **/
   DELIV_PROMPT,
   /**
    * Deliver messages immediately, skipping the event loop.
    *
    * Every event on this channel is flushed immediately after it is queued,
    * using the stack.
    *
    * This delivery type should be used with caution, since it can cause
    * unexpected call chains, resource starvation, and the like.
    **/
   DELIV_IMMEDIATE,
} deliv_strategy_t;

int tor_mainloop_connect_pubsub(struct pubsub_builder_t *builder);
void tor_mainloop_connect_pubsub_events(void);
int tor_mainloop_set_delivery_strategy(const char *msg_channel_name,
                                        deliv_strategy_t strategy);
void tor_mainloop_disconnect_pubsub(void);

#endif /* !defined(TOR_MAINLOOP_PUBSUB_H) */
