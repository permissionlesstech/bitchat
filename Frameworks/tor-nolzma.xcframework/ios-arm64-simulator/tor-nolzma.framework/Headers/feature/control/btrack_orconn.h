/* Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file btrack_orconn.h
 * \brief Header file for btrack_orconn.c
 **/

#ifndef TOR_BTRACK_ORCONN_H
#define TOR_BTRACK_ORCONN_H

#include "lib/pubsub/pubsub.h"

#ifdef BTRACK_ORCONN_PRIVATE

#include "ht.h"

/**
 * Structure for tracking OR connection states
 *
 * This gets linked into two hash maps: one with connection IDs, and
 * another with channel IDs.
 **/
typedef struct bt_orconn_t {
  HT_ENTRY(bt_orconn_t) node;   /**< Hash map entry indexed by gid */
  HT_ENTRY(bt_orconn_t) chan_node; /**< Hash map entry indexed by channel ID */
  uint64_t gid;                    /**< Global ID of this ORCONN */
  uint64_t chan;                   /**< Channel ID, if known */
  int proxy_type;                  /**< Proxy type */
  uint8_t state;                   /**< State of this ORCONN */
  bool is_orig;             /**< Does this carry an origin circuit? */
  bool is_onehop;           /**< Is this for a one-hop circuit? */
} bt_orconn_t;

#endif /* defined(BTRACK_ORCONN_PRIVATE) */

int btrack_orconn_init(void);
int btrack_orconn_add_pubsub(pubsub_connector_t *);
void btrack_orconn_fini(void);

#endif /* !defined(TOR_BTRACK_ORCONN_H) */
