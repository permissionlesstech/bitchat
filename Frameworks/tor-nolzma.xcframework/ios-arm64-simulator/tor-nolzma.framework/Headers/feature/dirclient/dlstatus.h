/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dlstatus.h
 * \brief Header file for dlstatus.c.
 **/

#ifndef TOR_DLSTATUS_H
#define TOR_DLSTATUS_H

time_t download_status_increment_failure(download_status_t *dls,
                                         int status_code, const char *item,
                                         int server, time_t now);
time_t download_status_increment_attempt(download_status_t *dls,
                                         const char *item,  time_t now);
/** Increment the failure count of the download_status_t <b>dls</b>, with
 * the optional status code <b>sc</b>. */
#define download_status_failed(dls, sc)                                 \
  download_status_increment_failure((dls), (sc), NULL,                  \
                                    dir_server_mode(get_options()), \
                                    time(NULL))

void download_status_reset(download_status_t *dls);
int download_status_is_ready(download_status_t *dls, time_t now);
time_t download_status_get_next_attempt_at(const download_status_t *dls);
void download_status_mark_impossible(download_status_t *dl);

int download_status_get_n_failures(const download_status_t *dls);
int download_status_get_n_attempts(const download_status_t *dls);

#ifdef DLSTATUS_PRIVATE
STATIC int download_status_schedule_get_delay(download_status_t *dls,
                                              int min_delay,
                                              time_t now);

STATIC int find_dl_min_delay(const download_status_t *dls,
                             const or_options_t *options);

STATIC int next_random_exponential_delay(int delay,
                                         int base_delay);

STATIC void next_random_exponential_delay_range(int *low_bound_out,
                                                int *high_bound_out,
                                                int delay,
                                                int base_delay);

/* no more than quadruple the previous delay (multiplier + 1) */
#define DIR_DEFAULT_RANDOM_MULTIPLIER (3)
/* no more than triple the previous delay */
#define DIR_TEST_NET_RANDOM_MULTIPLIER (2)

#endif /* defined(DLSTATUS_PRIVATE) */

#endif /* !defined(TOR_DLSTATUS_H) */
