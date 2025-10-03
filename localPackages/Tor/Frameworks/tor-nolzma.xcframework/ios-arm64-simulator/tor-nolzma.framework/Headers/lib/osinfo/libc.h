/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file libc.h
 * @brief Header for lib/osinfo/libc.c
 **/

#ifndef TOR_LIB_OSINFO_LIBC_H
#define TOR_LIB_OSINFO_LIBC_H

const char *tor_libc_get_name(void);
const char *tor_libc_get_version_str(void);
const char *tor_libc_get_header_version_str(void);

#endif /* !defined(TOR_LIB_OSINFO_LIBC_H) */
