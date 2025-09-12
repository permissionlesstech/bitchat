/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file nickname.h
 * \brief Header file for nickname.c.
 **/

#ifndef TOR_NICKNAME_H
#define TOR_NICKNAME_H

int is_legal_nickname(const char *s);
int is_legal_nickname_or_hexdigest(const char *s);
int is_legal_hexdigest(const char *s);

#endif /* !defined(TOR_NICKNAME_H) */
