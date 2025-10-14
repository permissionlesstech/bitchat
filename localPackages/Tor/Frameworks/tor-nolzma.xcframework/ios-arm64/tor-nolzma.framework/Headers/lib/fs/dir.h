/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_DIR_H
#define TOR_DIR_H

/**
 * \file dir.h
 *
 * \brief Header for dir.c
 **/

#include "lib/cc/compat_compiler.h"
#include "lib/testsupport/testsupport.h"

/** Possible behaviors for check_private_dir() on encountering a nonexistent
 * directory; see that function's documentation for details. */
typedef unsigned int cpd_check_t;
#define CPD_NONE                 0
#define CPD_CREATE               (1u << 0)
#define CPD_CHECK                (1u << 1)
#define CPD_GROUP_OK             (1u << 2)
#define CPD_GROUP_READ           (1u << 3)
#define CPD_CHECK_MODE_ONLY      (1u << 4)
#define CPD_RELAX_DIRMODE_CHECK  (1u << 5)
MOCK_DECL(int, check_private_dir, (const char *dirname, cpd_check_t check,
                                   const char *effective_user));

MOCK_DECL(struct smartlist_t *, tor_listdir, (const char *dirname));

#endif /* !defined(TOR_DIR_H) */
