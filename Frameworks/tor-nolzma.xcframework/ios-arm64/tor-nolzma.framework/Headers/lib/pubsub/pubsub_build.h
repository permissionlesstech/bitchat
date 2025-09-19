/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pubsub_build.h
 * @brief Header used for constructing the OO publish-subscribe facility.
 *
 * (See pubsub.h for more general information on this API.)
 **/

#ifndef TOR_PUBSUB_BUILD_H
#define TOR_PUBSUB_BUILD_H

#include "lib/dispatch/msgtypes.h"

struct dispatch_t;
struct pubsub_connector_t;

/**
 * A "dispatch builder" is an incomplete dispatcher, used when
 * registering messages.  It does not have the same integrity guarantees
 * as a dispatcher.  It cannot actually handle messages itself: once all
 * subsystems have registered, it is converted into a dispatch_t.
 **/
typedef struct pubsub_builder_t pubsub_builder_t;

/**
 * A "pubsub items" holds the configuration items used to configure a
 * pubsub_builder.  After the builder is finalized, this field is extracted,
 * and used later to tear down pointers that enable publishing.
 **/
typedef struct pubsub_items_t pubsub_items_t;

/**
 * Create a new pubsub_builder. This should only happen in the
 * main-init code.
 */
pubsub_builder_t *pubsub_builder_new(void);

/** DOCDOC */
int pubsub_builder_check(pubsub_builder_t *);

/**
 * Free a pubsub builder.  This should only happen on error paths, where
 * we have decided not to construct a dispatcher for some reason.
 */
#define pubsub_builder_free(db) \
  FREE_AND_NULL(pubsub_builder_t, pubsub_builder_free_, (db))

/** Internal implementation of pubsub_builder_free(). */
void pubsub_builder_free_(pubsub_builder_t *);

/**
 * Create a pubsub connector that a single subsystem will use to
 * register its messages.  The main-init code does this during subsystem
 * initialization.
 */
struct pubsub_connector_t *pubsub_connector_for_subsystem(pubsub_builder_t *,
                                                          subsys_id_t);

/**
 * The main-init code does this after subsystem initialization.
 */
#define pubsub_connector_free(c) \
  FREE_AND_NULL(struct pubsub_connector_t, pubsub_connector_free_, (c))

void pubsub_connector_free_(struct pubsub_connector_t *);

/**
 * Constructs a dispatcher from a dispatch_builder, after checking that the
 * invariances on the messages, channels, and connections have been
 * respected.
 *
 * This should happen after every subsystem has initialized, and before
 * entering the mainloop.
 */
struct dispatch_t *pubsub_builder_finalize(pubsub_builder_t *,
                                           pubsub_items_t **items_out);

/**
 * Clear all pub_binding_t backpointers in <b>items</b>.
 **/
void pubsub_items_clear_bindings(pubsub_items_t *items);

/**
 * @copydoc pubsub_items_free_
 *
 * Additionally, set the pointer <b>cfg</b> to NULL.
 **/
#define pubsub_items_free(cfg) \
  FREE_AND_NULL(pubsub_items_t, pubsub_items_free_, (cfg))
void pubsub_items_free_(pubsub_items_t *cfg);

#endif /* !defined(TOR_PUBSUB_BUILD_H) */
