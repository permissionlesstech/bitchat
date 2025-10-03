/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef CONTEXT_H
#define CONTEXT_H

#include <stdbool.h>

#include "hashx.h"
#include "blake2.h"
#include "siphash.h"
#include "program.h"

#ifdef __cplusplus
extern "C" {
#endif

HASHX_PRIVATE extern const blake2b_param hashx_blake2_params;

#ifdef __cplusplus
}
#endif

typedef struct hashx_program hashx_program;

/* HashX context. */
typedef struct hashx_ctx {
	uint8_t* compiler_mem;
	hashx_type ctx_type;
	hashx_type func_type;
	hashx_program program;
#ifndef HASHX_BLOCK_MODE
	siphash_state keys;
#else
	blake2b_param params;
#endif
} hashx_ctx;

#endif
