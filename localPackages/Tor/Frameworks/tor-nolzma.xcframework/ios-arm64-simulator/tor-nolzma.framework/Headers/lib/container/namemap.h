/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_NAMEMAP_H
#define TOR_NAMEMAP_H

/**
 * \file namemap.h
 *
 * \brief Header for namemap.c
 **/

#include "lib/cc/compat_compiler.h"
#include "ext/ht.h"

#include <stddef.h>

typedef struct namemap_t namemap_t;

/** Returned in place of an identifier when an error occurs. */
#define NAMEMAP_ERR UINT_MAX

void namemap_init(namemap_t *map);
const char *namemap_get_name(const namemap_t *map, unsigned id);
const char *namemap_fmt_name(const namemap_t *map, unsigned id);
unsigned namemap_get_id(const namemap_t *map,
                        const char *name);
unsigned namemap_get_or_create_id(namemap_t *map,
                                  const char *name);
size_t namemap_get_size(const namemap_t *map);
void namemap_clear(namemap_t *map);

#endif /* !defined(TOR_NAMEMAP_H) */
