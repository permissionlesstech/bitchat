/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file or_state_st.h
 *
 * \brief The or_state_t structure, which represents Tor's state file.
 */

#ifndef TOR_OR_STATE_ST_H
#define TOR_OR_STATE_ST_H

#include "lib/cc/torint.h"
struct smartlist_t;
struct config_suite_t;

/** Persistent state for an onion router, as saved to disk. */
struct or_state_t {
  uint32_t magic_;
  /** The time at which we next plan to write the state to the disk.  Equal to
   * TIME_MAX if there are no saveable changes, 0 if there are changes that
   * should be saved right away. */
  time_t next_write;

  /** When was the state last written to disk? */
  time_t LastWritten;

  /** Fields for accounting bandwidth use. */
  time_t AccountingIntervalStart;
  uint64_t AccountingBytesReadInInterval;
  uint64_t AccountingBytesWrittenInInterval;
  int AccountingSecondsActive;
  int AccountingSecondsToReachSoftLimit;
  time_t AccountingSoftLimitHitAt;
  uint64_t AccountingBytesAtSoftLimit;
  uint64_t AccountingExpectedUsage;

  /** A list of guard-related configuration lines. */
  struct config_line_t *Guard;

  struct config_line_t *TransportProxies;

  /** These fields hold information on the history of bandwidth usage for
   * servers.  The "Ends" fields hold the time when we last updated the
   * bandwidth usage. The "Interval" fields hold the granularity, in seconds,
   * of the entries of Values.  The "Values" lists hold decimal string
   * representations of the number of bytes read or written in each
   * interval. The "Maxima" list holds decimal strings describing the highest
   * rate achieved during the interval.
   */
  time_t      BWHistoryReadEnds;
  int         BWHistoryReadInterval;
  struct smartlist_t *BWHistoryReadValues;
  struct smartlist_t *BWHistoryReadMaxima;
  time_t      BWHistoryWriteEnds;
  int         BWHistoryWriteInterval;
  struct smartlist_t *BWHistoryWriteValues;
  struct smartlist_t *BWHistoryWriteMaxima;
  time_t      BWHistoryIPv6ReadEnds;
  int         BWHistoryIPv6ReadInterval;
  struct smartlist_t *BWHistoryIPv6ReadValues;
  struct smartlist_t *BWHistoryIPv6ReadMaxima;
  time_t      BWHistoryIPv6WriteEnds;
  int         BWHistoryIPv6WriteInterval;
  struct smartlist_t *BWHistoryIPv6WriteValues;
  struct smartlist_t *BWHistoryIPv6WriteMaxima;
  time_t      BWHistoryDirReadEnds;
  int         BWHistoryDirReadInterval;
  struct smartlist_t *BWHistoryDirReadValues;
  struct smartlist_t *BWHistoryDirReadMaxima;
  time_t      BWHistoryDirWriteEnds;
  int         BWHistoryDirWriteInterval;
  struct smartlist_t *BWHistoryDirWriteValues;
  struct smartlist_t *BWHistoryDirWriteMaxima;

  /** Build time histogram */
  struct config_line_t * BuildtimeHistogram;
  int TotalBuildTimes;
  int CircuitBuildAbandonedCount;

  /** What version of Tor wrote this state file? */
  char *TorVersion;

  /** Holds any unrecognized values we found in the state file, in the order
   * in which we found them. */
  struct config_line_t *ExtraLines;

  /** When did we last rotate our onion key?  "0" for 'no idea'. */
  time_t LastRotatedOnionKey;

  /**
   * State objects for individual modules.
   *
   * Never access this field or its members directly: instead, use the module
   * in question to get its relevant state object if you must.
   */
  struct config_suite_t *substates_;
};

#endif /* !defined(TOR_OR_STATE_ST_H) */
