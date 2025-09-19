/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file download_status_st.h
 * @brief Directory download status/schedule structure.
 **/

#ifndef DOWNLOAD_STATUS_ST_H
#define DOWNLOAD_STATUS_ST_H

/** Information about our plans for retrying downloads for a downloadable
 * directory object.
 * Each type of downloadable directory object has a corresponding retry
 * <b>schedule</b>, which can be different depending on whether the object is
 * being downloaded from an authority or a mirror (<b>want_authority</b>).
 * <b>next_attempt_at</b> contains the next time we will attempt to download
 * the object.
 * For schedules that <b>increment_on</b> failure, <b>n_download_failures</b>
 * is used to determine the position in the schedule. (Each schedule is a
 * smartlist of integer delays, parsed from a CSV option.) Every time a
 * connection attempt fails, <b>n_download_failures</b> is incremented,
 * the new delay value is looked up from the schedule, and
 * <b>next_attempt_at</b> is set delay seconds from the time the previous
 * connection failed. Therefore, at most one failure-based connection can be
 * in progress for each download_status_t.
 * For schedules that <b>increment_on</b> attempt, <b>n_download_attempts</b>
 * is used to determine the position in the schedule. Every time a
 * connection attempt is made, <b>n_download_attempts</b> is incremented,
 * the new delay value is looked up from the schedule, and
 * <b>next_attempt_at</b> is set delay seconds from the time the previous
 * connection was attempted. Therefore, multiple concurrent attempted-based
 * connections can be in progress for each download_status_t.
 * After an object is successfully downloaded, any other concurrent connections
 * are terminated. A new schedule which starts at position 0 is used for
 * subsequent downloads of the same object.
 */
struct download_status_t {
  time_t next_attempt_at; /**< When should we try downloading this object
                           * again? */
  uint8_t n_download_failures; /**< Number of failed downloads of the most
                                * recent object, since the last success. */
  uint8_t n_download_attempts; /**< Number of (potentially concurrent) attempts
                                * to download the most recent object, since
                                * the last success. */
  download_schedule_bitfield_t schedule : 8; /**< What kind of object is being
                                              * downloaded? This determines the
                                              * schedule used for the download.
                                              */
  download_want_authority_bitfield_t want_authority : 1; /**< Is the download
                                              * happening from an authority
                                              * or a mirror? This determines
                                              * the schedule used for the
                                              * download. */
  download_schedule_increment_bitfield_t increment_on : 1; /**< does this
                                        * schedule increment on each attempt,
                                        * or after each failure? */
  uint8_t last_backoff_position; /**< number of attempts/failures, depending
                                  * on increment_on, when we last recalculated
                                  * the delay.  Only updated if backoff
                                  * == 1. */
  int last_delay_used; /**< last delay used for random exponential backoff;
                        * only updated if backoff == 1 */
};

#endif /* !defined(DOWNLOAD_STATUS_ST_H) */
