/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pubsub.h
 * @brief Header for OO publish-subscribe functionality.
 *
 * This module provides a wrapper around the "dispatch" module,
 * ensuring type-safety and allowing us to do static analysis on
 * publication and subscriptions.
 *
 * With this module, we enforce:
 *  <ul>
 *   <li>that every message has (potential) publishers and subscribers;
 *   <li>that every message is published and subscribed from the correct
 *       channels, with the correct type ID, every time it is published.
 *   <li>that type IDs correspond to a single C type, and that the C types are
 *       used correctly.
 *   <li>that when a message is published or subscribed, it is done with
 *       a correct subsystem identifier
 * </ul>
 *
 * We do this by making "publication requests" and "subscription requests"
 * into objects, and doing some computation on them before we create
 * a dispatch_t with them.
 *
 * Rather than using the dispatch module directly, a publishing module
 * receives a "binding" object that it uses to send messages with the right
 * settings.
 *
 * Most users of this module will want to use this header, and the
 * pubsub_macros.h header for convenience.
 */

/*
 *
 * Overview: Messages are sent over channels.  Before sending a message on a
 * channel, or receiving a message on a channel, a subsystem needs to register
 * that it publishes, or subscribes, to that message, on that channel.
 *
 * Messages, channels, and subsystems are represented internally as short
 * integers, though they are associated with human-readable strings for
 * initialization and debugging.
 *
 * When registering for a message, a subsystem must say whether it is an
 * exclusive publisher/subscriber to that message type, or whether other
 * subsystems may also publish/subscribe to it.
 *
 * All messages and their publishers/subscribers must be registered early in
 * the initialization process.
 *
 * By default, it is an error for a message type to have publishers and no
 * subscribers on a channel, or subscribers and no publishers on a channel.
 *
 * A subsystem may register for a message with a note that delivery or
 * production is disabled -- for example, because the subsystem is
 * disabled at compile-time. It is not an error for a message type to
 * have all of its publishers or subscribers disabled.
 *
 * After a message is sent, it is delivered to every recipient.  This
 * delivery happens from the top level of the event loop; it may be
 * interleaved with network events, timers, etc.
 *
 * Messages may have associated data.  This data is typed, and is owned
 * by the message.  Strings, byte-arrays, and integers have built-in
 * support.  Other types may be added.  If objects are to be sent,
 * they should be identified by handle.  If an object requires cleanup,
 * it should be declared with an associated free function.
 *
 * Semantically, if two subsystems communicate only by this kind of
 * message passing, neither is considered to depend on the other, though
 * both are considered to have a dependency on the message and on any
 * types it contains.
 *
 * (Or generational index?)
 */
#ifndef TOR_PUBSUB_PUBSUB_H
#define TOR_PUBSUB_PUBSUB_H

#include "lib/pubsub/pub_binding_st.h"
#include "lib/pubsub/pubsub_connect.h"
#include "lib/pubsub/pubsub_flags.h"
#include "lib/pubsub/pubsub_macros.h"
#include "lib/pubsub/pubsub_publish.h"

#endif /* !defined(TOR_PUBSUB_PUBSUB_H) */
