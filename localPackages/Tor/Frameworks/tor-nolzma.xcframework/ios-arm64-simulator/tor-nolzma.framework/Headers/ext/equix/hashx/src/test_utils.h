/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef TEST_UTILS_H
#define TEST_UTILS_H

#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <hashx.h>

static inline void read_option(const char* option, int argc, char** argv, bool* out) {
	for (int i = 0; i < argc; ++i) {
		if (strcmp(argv[i], option) == 0) {
			*out = true;
			return;
		}
	}
	*out = false;
}

static inline void read_int_option(const char* option, int argc, char** argv, int* out, int default_val) {
	for (int i = 0; i < argc - 1; ++i) {
		if (strcmp(argv[i], option) == 0 && (*out = atoi(argv[i + 1])) > 0) {
			return;
		}
	}
	*out = default_val;
}

static inline char parse_nibble(char hex) {
	hex &= ~0x20;
	return (hex & 0x40) ? hex - ('A' - 10) : hex & 0xf;
}

static inline void hex2bin(const char* in, int length, char* out) {
	for (int i = 0; i < length; i += 2) {
		char nibble1 = parse_nibble(*in++);
		char nibble2 = parse_nibble(*in++);
		*out++ = nibble1 << 4 | nibble2;
	}
}

static inline void output_hex(const char* data, int length) {
	for (unsigned i = 0; i < length; ++i)
		printf("%02x", data[i] & 0xff);
}

static inline bool hashes_equal(char* a, char* b) {
	return memcmp(a, b, HASHX_SIZE) == 0;
}

static inline bool equals_hex(const void* hash, const char* hex) {
	char reference[HASHX_SIZE];
	hex2bin(hex, 2 * HASHX_SIZE, reference);
	return memcmp(hash, reference, sizeof(reference)) == 0;
}

#endif
