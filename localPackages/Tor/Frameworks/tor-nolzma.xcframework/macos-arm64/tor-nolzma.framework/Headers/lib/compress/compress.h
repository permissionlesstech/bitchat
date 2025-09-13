/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file compress.h
 * \brief Headers for compress.c
 **/

#ifndef TOR_COMPRESS_H
#define TOR_COMPRESS_H

#include <stddef.h>
#include "lib/testsupport/testsupport.h"

/** Enumeration of what kind of compression to use.  Only ZLIB_METHOD and
 * GZIP_METHOD is guaranteed to be supported by the compress/uncompress
 * functions here. Call tor_compress_supports_method() to check if a given
 * compression schema is supported by Tor. */
typedef enum compress_method_t {
  NO_METHOD=0, // This method must be first.
  GZIP_METHOD=1,
  ZLIB_METHOD=2,
  LZMA_METHOD=3,
  ZSTD_METHOD=4,
  UNKNOWN_METHOD=5, // This method must be last. Add new ones in the middle.
} compress_method_t;

/**
 * Enumeration to define tradeoffs between memory usage and compression level.
 * BEST_COMPRESSION saves the most bandwidth; LOW_COMPRESSION saves the most
 * memory.
 **/
typedef enum compression_level_t {
  BEST_COMPRESSION, HIGH_COMPRESSION, MEDIUM_COMPRESSION, LOW_COMPRESSION
} compression_level_t;

int tor_compress(char **out, size_t *out_len,
                 const char *in, size_t in_len,
                 compress_method_t method);

int tor_uncompress(char **out, size_t *out_len,
                   const char *in, size_t in_len,
                   compress_method_t method,
                   int complete_only,
                   int protocol_warn_level);

compress_method_t detect_compression_method(const char *in, size_t in_len);

MOCK_DECL(int,tor_compress_is_compression_bomb,(size_t size_in,
                                                size_t size_out));

int tor_compress_supports_method(compress_method_t method);
unsigned tor_compress_get_supported_method_bitmask(void);
const char *compression_method_get_name(compress_method_t method);
const char *compression_method_get_human_name(compress_method_t method);
compress_method_t compression_method_get_by_name(const char *name);

const char *tor_compress_version_str(compress_method_t method);

const char *tor_compress_header_version_str(compress_method_t method);

size_t tor_compress_get_total_allocation(void);

/** Return values from tor_compress_process; see that function's documentation
 * for details. */
typedef enum {
  TOR_COMPRESS_OK,
  TOR_COMPRESS_DONE,
  TOR_COMPRESS_BUFFER_FULL,
  TOR_COMPRESS_ERROR
} tor_compress_output_t;

/** Internal state for an incremental compression/decompression. */
typedef struct tor_compress_state_t tor_compress_state_t;

tor_compress_state_t *tor_compress_new(int compress,
                                       compress_method_t method,
                                       compression_level_t level);

tor_compress_output_t tor_compress_process(tor_compress_state_t *state,
                                           char **out, size_t *out_len,
                                           const char **in, size_t *in_len,
                                           int finish);
void tor_compress_free_(tor_compress_state_t *state);
#define tor_compress_free(st) \
  FREE_AND_NULL(tor_compress_state_t, tor_compress_free_, (st))

size_t tor_compress_state_size(const tor_compress_state_t *state);

int tor_compress_init(void);
void tor_compress_log_init_warnings(void);

struct buf_t;
int buf_add_compress(struct buf_t *buf, struct tor_compress_state_t *state,
                     const char *data, size_t data_len, int done);

#endif /* !defined(TOR_COMPRESS_H) */
