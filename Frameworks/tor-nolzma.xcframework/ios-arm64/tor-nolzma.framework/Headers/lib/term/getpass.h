/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file getpass.h
 * \brief Header for getpass.c
 **/

#ifndef TOR_GETPASS_H
#define TOR_GETPASS_H

#include "lib/cc/torint.h"

ssize_t tor_getpass(const char *prompt, char *output, size_t buflen);

#endif /* !defined(TOR_GETPASS_H) */
