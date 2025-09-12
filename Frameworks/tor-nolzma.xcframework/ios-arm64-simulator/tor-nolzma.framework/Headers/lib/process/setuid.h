/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file setuid.h
 * \brief Header for setuid.c
 **/

#ifndef TOR_SETUID_H
#define TOR_SETUID_H

int have_capability_support(void);

/** Flag for switch_id; see switch_id() for documentation */
#define SWITCH_ID_KEEP_BINDLOW    (1<<0)
/** Flag for switch_id; see switch_id() for documentation */
#define SWITCH_ID_WARN_IF_NO_CAPS (1<<1)
int switch_id(const char *user, unsigned flags);

#endif /* !defined(TOR_SETUID_H) */
