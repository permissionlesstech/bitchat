/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file buffers.h
 *
 * \brief Header file for buffers.c.
 **/

#ifndef TOR_BUFFERS_H
#define TOR_BUFFERS_H

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"

#include <stdarg.h>

typedef struct buf_t buf_t;

buf_t *buf_new(void);
buf_t *buf_new_with_capacity(size_t size);
size_t buf_get_default_chunk_size(const buf_t *buf);
void buf_free_(buf_t *buf);
#define buf_free(b) FREE_AND_NULL(buf_t, buf_free_, (b))
void buf_clear(buf_t *buf);
buf_t *buf_copy(const buf_t *buf);

/** Maximum bytes in a buffer, inclusive. */
#define BUF_MAX_LEN (INT_MAX - 1)

MOCK_DECL(size_t, buf_datalen, (const buf_t *buf));
size_t buf_allocation(const buf_t *buf);
size_t buf_slack(const buf_t *buf);

uint32_t buf_get_oldest_chunk_timestamp(const buf_t *buf, uint32_t now);
size_t buf_get_total_allocation(void);

int buf_add(buf_t *buf, const char *string, size_t string_len);
void buf_add_string(buf_t *buf, const char *string);
void buf_add_printf(buf_t *buf, const char *format, ...)
  CHECK_PRINTF(2, 3);
void buf_add_vprintf(buf_t *buf, const char *format, va_list args)
  CHECK_PRINTF(2, 0);
int buf_move_to_buf(buf_t *buf_out, buf_t *buf_in, size_t *buf_flushlen);
size_t buf_move_all(buf_t *buf_out, buf_t *buf_in);
void buf_peek(const buf_t *buf, char *string, size_t string_len);
void buf_drain(buf_t *buf, size_t n);
int buf_get_bytes(buf_t *buf, char *string, size_t string_len);
int buf_get_line(buf_t *buf, char *data_out, size_t *data_len);

#define PEEK_BUF_STARTSWITH_MAX 16
int buf_peek_startswith(const buf_t *buf, const char *cmd);

int buf_set_to_copy(buf_t **output,
                    const buf_t *input);

void buf_assert_ok(buf_t *buf);

int buf_find_string_offset(const buf_t *buf, const char *s, size_t n);
void buf_pullup(buf_t *buf, size_t bytes,
                const char **head_out, size_t *len_out);
char *buf_extract(buf_t *buf, size_t *sz_out);

#ifdef BUFFERS_PRIVATE
#ifdef TOR_UNIT_TESTS
buf_t *buf_new_with_data(const char *cp, size_t sz);
#endif
size_t buf_preferred_chunk_size(size_t target);

#define DEBUG_CHUNK_ALLOC
/** A single chunk on a buffer. */
typedef struct chunk_t {
  struct chunk_t *next; /**< The next chunk on the buffer. */
  size_t datalen; /**< The number of bytes stored in this chunk */
  size_t memlen; /**< The number of usable bytes of storage in <b>mem</b>. */
#ifdef DEBUG_CHUNK_ALLOC
  size_t DBG_alloc;
#endif
  char *data; /**< A pointer to the first byte of data stored in <b>mem</b>. */
  uint32_t inserted_time; /**< Timestamp when this chunk was inserted. */
  char mem[FLEXIBLE_ARRAY_MEMBER]; /**< The actual memory used for storage in
                * this chunk. */
} chunk_t;

/** Magic value for buf_t.magic, to catch pointer errors. */
#define BUFFER_MAGIC 0xB0FFF312u
/** A resizeable buffer, optimized for reading and writing. */
struct buf_t {
  uint32_t magic; /**< Magic cookie for debugging: Must be set to
                   *   BUFFER_MAGIC. */
  size_t datalen; /**< How many bytes is this buffer holding right now? */
  size_t default_chunk_size; /**< Don't allocate any chunks smaller than
                              * this for this buffer. */
  chunk_t *head; /**< First chunk in the list, or NULL for none. */
  chunk_t *tail; /**< Last chunk in the list, or NULL for none. */
};

chunk_t *buf_add_chunk_with_capacity(buf_t *buf, size_t capacity, int capped);
/** If a read onto the end of a chunk would be smaller than this number, then
 * just start a new chunk. */
#define MIN_READ_LEN 8

/** Return the number of bytes that can be written onto <b>chunk</b> without
 * running out of space. */
static inline size_t
CHUNK_REMAINING_CAPACITY(const chunk_t *chunk)
{
  return (chunk->mem + chunk->memlen) - (chunk->data + chunk->datalen);
}

/** Return the next character in <b>chunk</b> onto which data can be appended.
 * If the chunk is full, this might be off the end of chunk->mem. */
static inline char *
CHUNK_WRITE_PTR(chunk_t *chunk)
{
  return chunk->data + chunk->datalen;
}

#endif /* defined(BUFFERS_PRIVATE) */

#endif /* !defined(TOR_BUFFERS_H) */
