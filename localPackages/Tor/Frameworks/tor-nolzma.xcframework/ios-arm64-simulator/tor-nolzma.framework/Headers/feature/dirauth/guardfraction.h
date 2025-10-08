/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file guardfraction.h
 * \brief Header file for guardfraction.c
 **/

#ifndef TOR_GUARDFRACTION_H
#define TOR_GUARDFRACTION_H

#ifdef GUARDFRACTION_PRIVATE
STATIC int
dirserv_read_guardfraction_file_from_str(const char *guardfraction_file_str,
                                      smartlist_t *vote_routerstatuses);
#endif

int dirserv_read_guardfraction_file(const char *fname,
                                 smartlist_t *vote_routerstatuses);

#endif /* !defined(TOR_GUARDFRACTION_H) */
