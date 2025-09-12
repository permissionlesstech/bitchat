/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file ratelim.h
 * \brief Summarize similar messages that would otherwise flood the logs.
 **/

#ifndef TOR_RATELIM_H
#define TOR_RATELIM_H

#include <time.h>

/* Rate-limiter */

/** A ratelim_t remembers how often an event is occurring, and how often
 * it's allowed to occur.  Typical usage is something like:
 *
   <pre>
    if (possibly_very_frequent_event()) {
      const int INTERVAL = 300;
      static ratelim_t warning_limit = RATELIM_INIT(INTERVAL);
      char *m;
      if ((m = rate_limit_log(&warning_limit, approx_time()))) {
        log_warn(LD_GENERAL, "The event occurred!%s", m);
        tor_free(m);
      }
    }
   </pre>

   As a convenience wrapper for logging, you can replace the above with:
   <pre>
   if (possibly_very_frequent_event()) {
     static ratelim_t warning_limit = RATELIM_INIT(300);
     log_fn_ratelim(&warning_limit, LOG_WARN, LD_GENERAL,
                    "The event occurred!");
   }
   </pre>
 */
typedef struct ratelim_t {
  /** How many seconds must elapse between log messages? */
  int rate;
  /** When did this limiter last allow a message to appear? */
  time_t last_allowed;
  /** When did this limiter start suppressing messages? */
  time_t started_limiting;
  /** How many messages has this limiter suppressed since it last allowed
   * one to appear? */
  int n_calls_since_last_time;
} ratelim_t;

#ifndef COCCI
#define RATELIM_INIT(r) { (r), 0, 0, 0 }
#endif
#define RATELIM_TOOMANY (16*1000*1000)

char *rate_limit_log(ratelim_t *lim, time_t now);

#endif /* !defined(TOR_RATELIM_H) */
