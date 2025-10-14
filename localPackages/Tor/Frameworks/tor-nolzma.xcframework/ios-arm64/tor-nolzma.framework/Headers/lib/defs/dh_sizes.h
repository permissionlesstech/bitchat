/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dh_sizes.h

 * \brief Definitions for sizes of Diffie-Hellman groups elements in Z_p.
 *
 * Tor uses these definitions throughout its codebase, even in parts that
 * don't actually do any Diffie-Hellman calculations.
 **/

#ifndef TOR_DH_SIZES_H
#define TOR_DH_SIZES_H

/** Length of our legacy DH keys. */
#define DH1024_KEY_LEN (1024/8)

#endif /* !defined(TOR_DH_SIZES_H) */
