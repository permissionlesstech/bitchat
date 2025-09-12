/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_CONFFILE_H
#define TOR_CONFFILE_H

/**
 * \file conffile.h
 *
 * \brief Header for conffile.c
 **/

struct smartlist_t;
struct config_line_t;

int config_get_lines_include(const char *string, struct config_line_t **result,
                             int extended, int *has_include,
                             struct smartlist_t *opened_lst);

#endif /* !defined(TOR_CONFFILE_H) */
