/* Copyright (c) 2023, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compat_blake2.h
 *
 * \brief Compatibility adapter providing blake2b using ext/equix/hashx
 **/

#ifndef TOR_COMPAT_BLAKE2_H
#define TOR_COMPAT_BLAKE2_H

#include <stddef.h>
#include <string.h>
#include "lib/cc/compat_compiler.h"
#include "ext/equix/hashx/src/blake2.h"

static inline int
blake2b_init_param(blake2b_state *S, const blake2b_param *P)
{
    return hashx_blake2b_init_param(S, P);
}

static inline int
blake2b_init(blake2b_state *S, const uint8_t digest_length)
{
    blake2b_param P;
    memset(&P, 0, sizeof P);
    P.digest_length = digest_length;
    P.fanout = 1;
    P.depth = 1;
    return blake2b_init_param(S, &P);
}

static inline int
blake2b_update(blake2b_state *S, const uint8_t *in, uint64_t inlen)
{
    return hashx_blake2b_update(S, in, inlen);
}

static inline int
blake2b_final(blake2b_state *S, uint8_t *out, uint8_t outlen)
{
    return hashx_blake2b_final(S, out, outlen);
}

#endif /* !defined(TOR_COMPAT_BLAKE2_H) */
