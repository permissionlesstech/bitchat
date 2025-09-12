/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file kvline.h
 *
 * \brief Header for kvline.c
 **/

#ifndef TOR_KVLINE_H
#define TOR_KVLINE_H

struct config_line_t;

#define KV_QUOTED    (1u<<0)
#define KV_OMIT_KEYS (1u<<1)
#define KV_OMIT_VALS (1u<<2)
#define KV_QUOTED_QSTRING (1u<<3)
#define KV_RAW       (1u<<4)

struct config_line_t *kvline_parse(const char *line, unsigned flags);
char *kvline_encode(const struct config_line_t *line, unsigned flags);

#endif /* !defined(TOR_KVLINE_H) */
