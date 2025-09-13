/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef SIPHASH_GENERATOR_H
#define SIPHASH_GENERATOR_H

#include <stdint.h>
#include <hashx.h>
#include "siphash.h"

typedef struct siphash_rng {
	siphash_state keys;
	uint64_t counter;
	uint64_t buffer8, buffer32;
	unsigned count8, count32;
#ifdef HASHX_RNG_CALLBACK
	void (*callback)(uint64_t *buffer, void *user_data);
	void *callback_user_data;
#endif
} siphash_rng;

#ifdef __cplusplus
extern "C" {
#endif

HASHX_PRIVATE void hashx_siphash_rng_init(siphash_rng* gen, const siphash_state* state);
HASHX_PRIVATE uint32_t hashx_siphash_rng_u32(siphash_rng* gen);
HASHX_PRIVATE uint8_t hashx_siphash_rng_u8(siphash_rng* gen);

#ifdef __cplusplus
}
#endif

#endif
