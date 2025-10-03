/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file fdio.h
 *
 * \brief Header for fdio.c
 **/

#ifndef TOR_FDIO_H
#define TOR_FDIO_H

#include <stddef.h>
#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif

off_t tor_fd_getpos(int fd);
int tor_fd_setpos(int fd, off_t pos);
int tor_fd_seekend(int fd);
int tor_ftruncate(int fd);
int write_all_to_fd_minimal(int fd, const char *buf, size_t count);

#endif /* !defined(TOR_FDIO_H) */
