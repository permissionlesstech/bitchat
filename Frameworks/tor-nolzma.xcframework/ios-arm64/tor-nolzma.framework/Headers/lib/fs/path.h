/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file path.h
 *
 * \brief Header for path.c
 **/

#ifndef TOR_PATH_H
#define TOR_PATH_H

#include <stdbool.h>
#ifdef _WIN32
#include <windows.h>
#endif
#include "lib/cc/compat_compiler.h"

#ifdef _WIN32
#define PATH_SEPARATOR "\\"
#else
#define PATH_SEPARATOR "/"
#endif

char *get_unquoted_path(const char *path);
char *expand_filename(const char *filename);
int path_is_relative(const char *filename);
void clean_fname_for_stat(char *name);
int get_parent_directory(char *fname);
char *make_path_absolute(const char *fname);
struct smartlist_t *tor_glob(const char *pattern);
bool has_glob(const char *s);
struct smartlist_t *get_glob_opened_files(const char *pattern);

#endif /* !defined(TOR_PATH_H) */
