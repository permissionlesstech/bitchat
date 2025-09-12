/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file dsigs_parse.h
 * \brief Header file for dsigs_parse.c.
 **/

#ifndef TOR_DSIGS_PARSE_H
#define TOR_DSIGS_PARSE_H

ns_detached_signatures_t *networkstatus_parse_detached_signatures(
                                      const char *s, const char *eos);

void ns_detached_signatures_free_(ns_detached_signatures_t *s);
#define ns_detached_signatures_free(s) \
  FREE_AND_NULL(ns_detached_signatures_t, ns_detached_signatures_free_, (s))

#endif /* !defined(TOR_DSIGS_PARSE_H) */
