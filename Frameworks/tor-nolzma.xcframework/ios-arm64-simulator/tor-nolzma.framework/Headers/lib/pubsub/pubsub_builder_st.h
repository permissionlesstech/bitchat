/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pubsub_builder_st.h
 *
 * @brief private structures used for configuring dispatchers and messages.
 */

#ifndef TOR_PUBSUB_BUILDER_ST_H
#define TOR_PUBSUB_BUILDER_ST_H

#ifdef PUBSUB_PRIVATE

#include <stdbool.h>
#include <stddef.h>

struct dispatch_cfg_t;
struct smartlist_t;
struct pub_binding_t;

/**
 * Configuration for a single publication or subscription request.
 *
 * These can be stored while the dispatcher is in use, but are only used for
 * setup, teardown, and debugging.
 *
 * There are various fields in this request describing the message; all of
 * them must match other descriptions of the message, or a bug has occurred.
 **/
typedef struct pubsub_cfg_t {
  /** True if this is a publishing request; false for a subscribing request. */
  bool is_publish;
  /** The system making this request. */
  subsys_id_t subsys;
  /** The channel on which the message is to be sent. */
  channel_id_t channel;
  /** The message ID to be sent or received. */
  message_id_t msg;
  /** The C type associated with the message. */
  msg_type_id_t type;
  /** One or more DISP_FLAGS_* items, combined with bitwise OR. */
  unsigned flags;

  /**
   * Publishing only: a pub_binding object that will receive the binding for
   * this request.  We will finish filling this in when the dispatcher is
   * constructed, so that the subsystem can publish then and not before.
   */
  struct pub_binding_t *pub_binding;

  /**
   * Subscribing only: a function to receive message objects for this request.
   */
  recv_fn_t recv_fn;

  /** The file from which this message was configured */
  const char *added_by_file;
  /** The line at which this message was configured */
  unsigned added_by_line;
} pubsub_cfg_t;

/**
 * Configuration request for a single C type.
 *
 * These are stored while the dispatcher is in use, but are only used for
 * setup, teardown, and debugging.
 **/
typedef struct pubsub_type_cfg_t {
  /**
   * The identifier for this type.
   */
  msg_type_id_t type;
  /**
   * Functions to use when manipulating the type.
   */
  dispatch_typefns_t fns;

  /** The subsystem that configured this type. */
  subsys_id_t subsys;
  /** The file from which this type was configured */
  const char *added_by_file;
  /** The line at which this type was configured */
  unsigned added_by_line;
} pubsub_type_cfg_t;

/**
 * The set of configuration requests for a dispatcher, as made by various
 * subsystems.
 **/
struct pubsub_items_t {
  /** List of pubsub_cfg_t. */
  struct smartlist_t *items;
  /** List of pubsub_type_cfg_t. */
  struct smartlist_t *type_items;
};

/**
 * Type used to construct a dispatcher.  We use this type to build up the
 * configuration for a dispatcher, and then pass ownership of that
 * configuration to the newly constructed dispatcher.
 **/
struct pubsub_builder_t {
  /** Number of outstanding pubsub_connector_t objects pointing to this
   * pubsub_builder_t. */
  int n_connectors;
  /** Number of errors encountered while constructing this object so far. */
  int n_errors;
  /** In-progress configuration that we're constructing, as a list of the
   * requests that have been made. */
  struct pubsub_items_t *items;
  /** In-progress configuration that we're constructing, in a form that can
   * be converted to a dispatch_t. */
  struct dispatch_cfg_t *cfg;
};

/**
 * Type given to a subsystem when adding connections to a pubsub_builder_t.
 * We use this type to force each subsystem to get blamed for the
 * publications, subscriptions, and types that it adds.
 **/
struct pubsub_connector_t {
  /** The pubsub_builder that this connector refers to. */
  struct pubsub_builder_t *builder;
  /** The subsystem that has been given this connector. */
  subsys_id_t subsys_id;
};

/**
 * Helper structure used when constructing a dispatcher that sorts the
 * pubsub_cfg_t objects in various ways.
 **/
typedef struct pubsub_adjmap_t {
  /* XXXX The next three fields are currently constructed but not yet
   * XXXX used. I believe we'll want them in the future, though. -nickm
   */
  /** Number of subsystems; length of the *_by_subsys arrays. */
  size_t n_subsystems;
  /** Array of lists of publisher pubsub_cfg_t objects, indexed by
   * subsystem. */
  struct smartlist_t **pub_by_subsys;
  /** Array of lists of subscriber pubsub_cfg_t objects, indexed by
   * subsystem. */
  struct smartlist_t **sub_by_subsys;

  /** Number of message IDs; length of the *_by_msg arrays. */
  size_t n_msgs;
  /** Array of lists of publisher pubsub_cfg_t objects, indexed by
   * message ID. */
  struct smartlist_t **pub_by_msg;
  /** Array of lists of subscriber pubsub_cfg_t objects, indexed by
   * message ID. */
  struct smartlist_t **sub_by_msg;
} pubsub_adjmap_t;

#endif /* defined(PUBSUB_PRIVATE) */

#endif /* !defined(TOR_PUBSUB_BUILDER_ST_H) */
