/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dispatch_naming.h
 * @brief Header for dispatch_naming.c
 **/

#ifndef TOR_DISPATCH_NAMING_H
#define TOR_DISPATCH_NAMING_H

#include "lib/dispatch/msgtypes.h"
#include <stddef.h>

/**
 * Return an existing channel ID by name, allocating the channel ID if
 * if necessary.  Returns ERROR_ID if we have run out of
 * channels
 */
channel_id_t get_channel_id(const char *);
/**
 * Return the name corresponding to a given channel ID.
 **/
const char *get_channel_id_name(channel_id_t);
/**
 * Return the total number of _named_ channel IDs.
 **/
size_t get_num_channel_ids(void);

/* As above, but for messages. */
message_id_t get_message_id(const char *);
const char *get_message_id_name(message_id_t);
size_t get_num_message_ids(void);

/* As above, but for subsystems */
subsys_id_t get_subsys_id(const char *);
const char *get_subsys_id_name(subsys_id_t);
size_t get_num_subsys_ids(void);

/* As above, but for types. Note that types additionally must be
 * "defined", if any message is to use them. */
msg_type_id_t get_msg_type_id(const char *);
const char *get_msg_type_id_name(msg_type_id_t);
size_t get_num_msg_type_ids(void);

void dispatch_naming_init(void);

#endif /* !defined(TOR_DISPATCH_NAMING_H) */
