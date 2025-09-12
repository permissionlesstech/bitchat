/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file mmap.h
 *
 * \brief Header for mmap.c
 **/

#ifndef TOR_MMAP_H
#define TOR_MMAP_H

#include "lib/cc/compat_compiler.h"
#include "lib/testsupport/testsupport.h"
#include <stddef.h>

#ifdef _WIN32
#include <windef.h>
#endif

/** Represents an mmaped file. Allocated via tor_mmap_file; freed with
 * tor_munmap_file. */
typedef struct tor_mmap_t {
  const char *data; /**< Mapping of the file's contents. */
  size_t size; /**< Size of the file. */

  /* None of the fields below should be accessed from outside compat.c */
#ifdef HAVE_MMAP
  size_t mapping_size; /**< Size of the actual mapping. (This is this file
                        * size, rounded up to the nearest page.) */
#elif defined _WIN32
  HANDLE mmap_handle;
#endif /* defined(HAVE_MMAP) || ... */

} tor_mmap_t;

MOCK_DECL(tor_mmap_t *, tor_mmap_file, (const char *filename));
MOCK_DECL(int, tor_munmap_file, (tor_mmap_t *handle));

#endif /* !defined(TOR_MMAP_H) */
