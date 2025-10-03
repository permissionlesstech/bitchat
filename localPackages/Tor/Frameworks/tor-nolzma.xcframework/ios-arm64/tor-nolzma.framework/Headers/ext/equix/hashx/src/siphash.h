/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef SIPHASH_H
#define SIPHASH_H

#include <stdint.h>
#include <hashx.h>

#define ROTL(x, b) (((x) << (b)) | ((x) >> (64 - (b))))
#define SIPROUND(v0, v1, v2, v3) \
  do { \
    v0 += v1; v2 += v3; v1 = ROTL(v1, 13);   \
    v3 = ROTL(v3, 16); v1 ^= v0; v3 ^= v2;   \
    v0 = ROTL(v0, 32); v2 += v1; v0 += v3;   \
    v1 = ROTL(v1, 17);  v3 = ROTL(v3, 21);   \
    v1 ^= v2; v3 ^= v0; v2 = ROTL(v2, 32);   \
  } while (0)

typedef struct siphash_state {
    uint64_t v0, v1, v2, v3;
} siphash_state;

#ifdef __cplusplus
extern "C" {
#endif

HASHX_PRIVATE uint64_t hashx_siphash13_ctr(uint64_t input, const siphash_state* keys);
HASHX_PRIVATE void hashx_siphash24_ctr_state512(const siphash_state* keys, uint64_t input, uint64_t state_out[8]);

#ifdef __cplusplus
}
#endif

#endif
