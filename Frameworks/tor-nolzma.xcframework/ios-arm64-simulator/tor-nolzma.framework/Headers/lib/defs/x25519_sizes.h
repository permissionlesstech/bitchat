/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file x25519_sizes.h

 * \brief Definitions for sizes of x25519 keys and elements.
 *
 * Tor uses these definitions throughout its codebase, even in parts that
 * don't actually do any x25519 calculations.
 **/

#ifndef TOR_X25519_SIZES_H
#define TOR_X25519_SIZES_H

/** Length of a curve25519 public key when encoded. */
#define CURVE25519_PUBKEY_LEN 32
/** Length of a curve25519 secret key when encoded. */
#define CURVE25519_SECKEY_LEN 32
/** Length of the result of a curve25519 handshake. */
#define CURVE25519_OUTPUT_LEN 32

/** Length of an Ed25519 public key */
#define ED25519_PUBKEY_LEN 32
/** Length of an Ed25519 secret key */
#define ED25519_SECKEY_LEN 64
/** Length of the seed that is ordinarily expanded to an Ed25519 secret
 * key. */
#define ED25519_SECKEY_SEED_LEN 32
/** Length of an Ed25519 signature. */
#define ED25519_SIG_LEN 64

/** Length of a Curve25519 key when encoded in base 64, with padding. */
#define CURVE25519_BASE64_PADDED_LEN 44

/** Length of a Curve25519 key when encoded in base 64, without padding. */
#define CURVE25519_BASE64_LEN 43

/** Length of a Ed25519 key when encoded in base 64, without padding. */
#define ED25519_BASE64_LEN 43
/** Length of a Ed25519 signature when encoded in base 64, without padding. */
#define ED25519_SIG_BASE64_LEN 86

#endif /* !defined(TOR_X25519_SIZES_H) */
