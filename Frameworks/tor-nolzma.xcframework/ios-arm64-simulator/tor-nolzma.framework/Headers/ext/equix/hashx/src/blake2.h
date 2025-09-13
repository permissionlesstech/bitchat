/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

/* Original code from Argon2 reference source code package used under CC0 Licence
 * https://github.com/P-H-C/phc-winner-argon2
 * Copyright 2015
 * Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves
*/

#ifndef PORTABLE_BLAKE2_H
#define PORTABLE_BLAKE2_H

#include <stdint.h>
#include <limits.h>
#include <stddef.h>
#include <hashx.h>

#if defined(__cplusplus)
extern "C" {
#endif

enum blake2b_constant {
	BLAKE2B_BLOCKBYTES = 128,
	BLAKE2B_OUTBYTES = 64,
	BLAKE2B_KEYBYTES = 64,
	BLAKE2B_SALTBYTES = 16,
	BLAKE2B_PERSONALBYTES = 16
};

#pragma pack(push, 1)
typedef struct blake2b_param {
	uint8_t digest_length;                   /* 1 */
	uint8_t key_length;                      /* 2 */
	uint8_t fanout;                          /* 3 */
	uint8_t depth;                           /* 4 */
	uint32_t leaf_length;                    /* 8 */
	uint64_t node_offset;                    /* 16 */
	uint8_t node_depth;                      /* 17 */
	uint8_t inner_length;                    /* 18 */
	uint8_t reserved[14];                    /* 32 */
	uint8_t salt[BLAKE2B_SALTBYTES];         /* 48 */
	uint8_t personal[BLAKE2B_PERSONALBYTES]; /* 64 */
} blake2b_param;
#pragma pack(pop)

typedef struct blake2b_state {
	uint64_t h[8];
	uint64_t t[2];
	uint64_t f[2];
	uint8_t buf[BLAKE2B_BLOCKBYTES];
	unsigned buflen;
	unsigned outlen;
	uint8_t last_node;
} blake2b_state;

/* Ensure param structs have not been wrongly padded */
/* Poor man's static_assert */
enum {
	blake2_size_check_0 = 1 / !!(CHAR_BIT == 8),
	blake2_size_check_2 =
	1 / !!(sizeof(blake2b_param) == sizeof(uint64_t) * CHAR_BIT)
};

HASHX_PRIVATE int hashx_blake2b_init_param(blake2b_state* S, const blake2b_param* P);
HASHX_PRIVATE int hashx_blake2b_update(blake2b_state* S, const void* in, size_t inlen);
HASHX_PRIVATE int hashx_blake2b_final(blake2b_state* S, void* out, size_t outlen);
HASHX_PRIVATE void hashx_blake2b_4r(const blake2b_param* P, const void* in, size_t inlen, void* out);

#if defined(__cplusplus)
}
#endif

#endif
