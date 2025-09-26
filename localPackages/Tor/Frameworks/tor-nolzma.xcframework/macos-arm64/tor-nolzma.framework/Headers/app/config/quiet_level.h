/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file quiet_level.h
 * \brief Declare the quiet_level enumeration and global.
 **/

#ifndef QUIET_LEVEL_H
#define QUIET_LEVEL_H

/** Enumeration to define how quietly Tor should log at startup. */
typedef enum {
   /** Default quiet level: we log everything of level NOTICE or higher. */
   QUIET_NONE = 0,
   /** "--hush" quiet level: we log everything of level WARNING or higher. */
   QUIET_HUSH = 1 ,
   /** "--quiet" quiet level: we log nothing at all. */
   QUIET_SILENT = 2
} quiet_level_t;

/** How quietly should Tor log at startup? */
extern quiet_level_t quiet_level;

void add_default_log_for_quiet_level(quiet_level_t quiet);

#endif /* !defined(QUIET_LEVEL_H) */
