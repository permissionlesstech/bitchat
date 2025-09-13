/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file fmt_routerstatus.h
 * \brief Header file for fmt_routerstatus.c.
 **/

#ifndef TOR_FMT_ROUTERSTATUS_H
#define TOR_FMT_ROUTERSTATUS_H

/** An enum to describe what format we're generating a routerstatus line in.
 */
typedef enum {
  /** For use in a v2 opinion */
  NS_V2,
  /** For use in a consensus networkstatus document (ns flavor) */
  NS_V3_CONSENSUS,
  /** For use in a vote networkstatus document */
  NS_V3_VOTE,
  /** For passing to the controlport in response to a GETINFO request */
  NS_CONTROL_PORT,
  /** For use in a consensus networkstatus document (microdesc flavor) */
  NS_V3_CONSENSUS_MICRODESC
} routerstatus_format_type_t;

/** Maximum allowable length of a version line in a networkstatus. */
#define MAX_V_LINE_LEN 128

char *routerstatus_format_entry(
                              const routerstatus_t *rs,
                              const char *version,
                              const char *protocols,
                              routerstatus_format_type_t format,
                              const vote_routerstatus_t *vrs,
                              time_t declared_publish_time);

#endif /* !defined(TOR_FMT_ROUTERSTATUS_H) */
