/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef PROGRAM_H
#define PROGRAM_H

#include <stdint.h>
#include <stdbool.h>
#include <hashx.h>
#include "instruction.h"
#include "siphash.h"
#include "blake2.h"

#define HASHX_PROGRAM_MAX_SIZE 512

typedef struct hashx_program {
	instruction code[HASHX_PROGRAM_MAX_SIZE];
	size_t code_size;
#ifdef HASHX_PROGRAM_STATS
	unsigned counter;
	double ipc;
	int x86_size;
	int cpu_latency;
	int asic_latency;
	int mul_count;
	int wide_mul_count;
	int cpu_latencies[8];
	int asic_latencies[8];
	int branch_count;
	int branches[16];
#endif
#ifdef HASHX_RNG_CALLBACK
	void (*rng_callback)(uint64_t *buffer, void *user_data);
	void *rng_callback_user_data;
#endif
} hashx_program;

#ifdef __cplusplus
extern "C" {
#endif

HASHX_PRIVATE bool hashx_program_generate(const siphash_state* key, hashx_program* program);

HASHX_PRIVATE void hashx_program_execute(const hashx_program* program, uint64_t r[8]);

HASHX_PRIVATE void hashx_program_asm_x86(const hashx_program* program);

#ifdef __cplusplus
}
#endif

#endif
