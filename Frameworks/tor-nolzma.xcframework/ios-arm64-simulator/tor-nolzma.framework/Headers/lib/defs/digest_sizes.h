/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_DIGEST_SIZES_H
#define TOR_DIGEST_SIZES_H

/**
 * \file digest_sizes.h
 *
 * \brief Definitions for common sizes of cryptographic digests.
 *
 * Tor uses digests throughout its codebase, even in parts that don't actually
 * calculate the digests.
 **/

/** Length of the output of our message digest. */
#define DIGEST_LEN 20
/** Length of the output of our second (improved) message digests.  (For now
 * this is just sha256, but it could be any other 256-bit digest.) */
#define DIGEST256_LEN 32
/** Length of the output of our 64-bit optimized message digests (SHA512). */
#define DIGEST512_LEN 64

#endif /* !defined(TOR_DIGEST_SIZES_H) */
