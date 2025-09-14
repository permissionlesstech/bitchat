/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file bwhist.h
 * @brief Header for feature/stats/bwhist.c
 **/

#ifndef TOR_FEATURE_STATS_BWHIST_H
#define TOR_FEATURE_STATS_BWHIST_H

void bwhist_init(void);
void bwhist_free_all(void);

void bwhist_note_bytes_read(uint64_t num_bytes, time_t when, bool ipv6);
void bwhist_note_bytes_written(uint64_t num_bytes, time_t when, bool ipv6);
void bwhist_note_dir_bytes_read(uint64_t num_bytes, time_t when);
void bwhist_note_dir_bytes_written(uint64_t num_bytes, time_t when);

MOCK_DECL(int, bwhist_bandwidth_assess, (void));
char *bwhist_get_bandwidth_lines(void);
struct or_state_t;
void bwhist_update_state(struct or_state_t *state);
int bwhist_load_state(struct or_state_t *state, char **err);

#ifdef BWHIST_PRIVATE
typedef struct bw_array_t bw_array_t;
STATIC uint64_t find_largest_max(bw_array_t *b, int min_observation_time);
STATIC void commit_max(bw_array_t *b);
STATIC void advance_obs(bw_array_t *b);
STATIC bw_array_t *bw_array_new(void);
STATIC void add_obs(bw_array_t *b, time_t when, uint64_t n);
#define bw_array_free(val) \
  FREE_AND_NULL(bw_array_t, bw_array_free_, (val))
STATIC void bw_array_free_(bw_array_t *b);
STATIC size_t bwhist_fill_bandwidth_history(char *buf, size_t len,
                                            const bw_array_t *b);
#endif /* defined(BWHIST_PRIVATE) */

#ifdef TOR_UNIT_TESTS
extern struct bw_array_t *write_array;
#endif

#endif /* !defined(TOR_FEATURE_STATS_BWHIST_H) */
