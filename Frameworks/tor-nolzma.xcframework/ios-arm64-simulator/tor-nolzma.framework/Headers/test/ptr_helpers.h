/* Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_PTR_HELPERS_H
#define TOR_PTR_HELPERS_H

#include <stdint.h>

void *
cast_intptr_to_voidstar(intptr_t x);

intptr_t
cast_voidstar_to_intptr(void *x);

void *
cast_uintptr_to_voidstar(uintptr_t x);

uintptr_t
cast_voidstar_to_uintptr(void *x);

#endif /* !defined(TOR_PTR_HELPERS_H) */
