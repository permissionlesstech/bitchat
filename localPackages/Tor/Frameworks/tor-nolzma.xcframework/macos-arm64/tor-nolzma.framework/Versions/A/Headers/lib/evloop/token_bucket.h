/* Copyright (c) 2018-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file token_bucket.h
 * \brief Headers for token_bucket.c
 **/

#ifndef TOR_TOKEN_BUCKET_H
#define TOR_TOKEN_BUCKET_H

#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"

/** Largest allowable burst value for a token buffer. */
#define TOKEN_BUCKET_MAX_BURST INT32_MAX

/** A generic token buffer configuration: determines the number of tokens
 * added to the bucket in each time unit (the "rate"), and the maximum number
 * of tokens in the bucket (the "burst") */
typedef struct token_bucket_cfg_t {
  uint32_t rate;
  int32_t burst;
} token_bucket_cfg_t;

/** A raw token bucket, decoupled from its configuration and timestamp. */
typedef struct token_bucket_raw_t {
  int32_t bucket;
} token_bucket_raw_t;

void token_bucket_cfg_init(token_bucket_cfg_t *cfg,
                           uint32_t rate,
                           uint32_t burst);

void token_bucket_raw_adjust(token_bucket_raw_t *bucket,
                             const token_bucket_cfg_t *cfg);

void token_bucket_raw_reset(token_bucket_raw_t *bucket,
                            const token_bucket_cfg_t *cfg);

int token_bucket_raw_dec(token_bucket_raw_t *bucket,
                         ssize_t n);

int token_bucket_raw_refill_steps(token_bucket_raw_t *bucket,
                                  const token_bucket_cfg_t *cfg,
                                  const uint32_t elapsed_steps);

static inline size_t token_bucket_raw_get(const token_bucket_raw_t *bucket);
/** Return the current number of bytes set in a token bucket. */
static inline size_t
token_bucket_raw_get(const token_bucket_raw_t *bucket)
{
  return bucket->bucket >= 0 ? bucket->bucket : 0;
}

/** A convenience type containing all the pieces needed for a coupled
 * read-bucket and write-bucket that have the same rate limit, and which use
 * "timestamp units" (see compat_time.h) for their time. */
typedef struct token_bucket_rw_t {
  token_bucket_cfg_t cfg;
  token_bucket_raw_t read_bucket;
  token_bucket_raw_t write_bucket;
  uint32_t last_refilled_at_timestamp;
} token_bucket_rw_t;

void token_bucket_rw_init(token_bucket_rw_t *bucket,
                          uint32_t rate,
                          uint32_t burst,
                          uint32_t now_ts_stamp);

void token_bucket_rw_adjust(token_bucket_rw_t *bucket,
                            uint32_t rate, uint32_t burst);

void token_bucket_rw_reset(token_bucket_rw_t *bucket,
                           uint32_t now_ts_stamp);

#define TB_READ 1
#define TB_WRITE 2

int token_bucket_rw_refill(token_bucket_rw_t *bucket,
                           uint32_t now_ts_stamp);

int token_bucket_rw_dec_read(token_bucket_rw_t *bucket,
                             ssize_t n);
int token_bucket_rw_dec_write(token_bucket_rw_t *bucket,
                              ssize_t n);

int token_bucket_rw_dec(token_bucket_rw_t *bucket,
                        ssize_t n_read, ssize_t n_written);

static inline size_t token_bucket_rw_get_read(const token_bucket_rw_t *bucket);
static inline size_t
token_bucket_rw_get_read(const token_bucket_rw_t *bucket)
{
  return token_bucket_raw_get(&bucket->read_bucket);
}

static inline size_t token_bucket_rw_get_write(
                                            const token_bucket_rw_t *bucket);
static inline size_t
token_bucket_rw_get_write(const token_bucket_rw_t *bucket)
{
  return token_bucket_raw_get(&bucket->write_bucket);
}

/**
 * A specialized bucket containing a single counter.
 */

typedef struct token_bucket_ctr_t {
  token_bucket_cfg_t cfg;
  token_bucket_raw_t counter;
  uint32_t last_refilled_at_timestamp;
} token_bucket_ctr_t;

void token_bucket_ctr_init(token_bucket_ctr_t *bucket, uint32_t rate,
                           uint32_t burst, uint32_t now_ts_sec);
void token_bucket_ctr_adjust(token_bucket_ctr_t *bucket, uint32_t rate,
                             uint32_t burst);
void token_bucket_ctr_reset(token_bucket_ctr_t *bucket, uint32_t now_ts_sec);
void token_bucket_ctr_refill(token_bucket_ctr_t *bucket, uint32_t now_ts_sec);

static inline bool
token_bucket_ctr_dec(token_bucket_ctr_t *bucket, ssize_t n)
{
  return token_bucket_raw_dec(&bucket->counter, n);
}

static inline size_t
token_bucket_ctr_get(const token_bucket_ctr_t *bucket)
{
  return token_bucket_raw_get(&bucket->counter);
}

#ifdef TOKEN_BUCKET_PRIVATE

/* To avoid making the rates too small, we consider units of "steps",
 * where a "step" is defined as this many timestamp ticks.  Keep this
 * a power of two if you can. */
#define TICKS_PER_STEP 16

STATIC uint32_t rate_per_sec_to_rate_per_step(uint32_t rate);

#endif /* defined(TOKEN_BUCKET_PRIVATE) */

#endif /* !defined(TOR_TOKEN_BUCKET_H) */
