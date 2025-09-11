/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file pubsub_flags.h
 * @brief Flags that can be set on publish/subscribe messages.
 **/

#ifndef TOR_PUBSUB_FLAGS_H
#define TOR_PUBSUB_FLAGS_H

/**
 * Flag for registering a message: declare that no other module is allowed to
 * publish this message if we are publishing it, or subscribe to it if we are
 * subscribing to it.
 */
#define DISP_FLAG_EXCL (1u<<0)

/**
 * Flag for registering a message: declare that this message is a stub, and we
 * will not actually publish/subscribe it, but that the dispatcher should
 * treat us as if we did when typechecking.
 *
 * We use this so that messages aren't treated as "dangling" if they are
 * potentially used by some other build of Tor.
 */
#define DISP_FLAG_STUB (1u<<1)

#endif /* !defined(TOR_PUBSUB_FLAGS_H) */
