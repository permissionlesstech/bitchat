/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file recommend_pkg.h
 * \brief Header file for recommend_pkg.c
 **/

#ifndef TOR_RECOMMEND_PKG_H
#define TOR_RECOMMEND_PKG_H

#ifdef HAVE_MODULE_DIRAUTH
int validate_recommended_package_line(const char *line);

#else

static inline int
validate_recommended_package_line(const char *line)
{
  (void) line;
  return 0;
}

#endif /* defined(HAVE_MODULE_DIRAUTH) */

#endif /* !defined(TOR_RECOMMEND_PKG_H) */
