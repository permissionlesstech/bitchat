/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dirauth_sys.h
 * @brief Header for dirauth_sys.c
 **/

#ifndef DIRAUTH_SYS_H
#define DIRAUTH_SYS_H

struct dirauth_options_t;
const struct dirauth_options_t *dirauth_get_options(void);

extern const struct subsys_fns_t sys_dirauth;

/**
 * Subsystem level for the directory-authority system.
 *
 * Defined here so that it can be shared between the real and stub
 * definitions.
 **/
#define DIRAUTH_SUBSYS_LEVEL 70

#ifdef DIRAUTH_SYS_PRIVATE
STATIC int dirauth_set_options(void *arg);
#endif

#endif /* !defined(DIRAUTH_SYS_H) */
