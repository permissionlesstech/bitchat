/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file pem.h
 *
 * \brief Header for pem.c
 **/

#ifndef TOR_PEM_H
#define TOR_PEM_H

#include "orconfig.h"
#include <stddef.h>
#include "lib/cc/torint.h"

size_t pem_encoded_size(size_t src_len, const char *objtype);
int pem_encode(char *dest, size_t destlen, const uint8_t *src, size_t srclen,
               const char *objtype);
int pem_decode(uint8_t *dest, size_t destlen, const char *src, size_t srclen,
               const char *objtype);

#endif /* !defined(TOR_PEM_H) */
