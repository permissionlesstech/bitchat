/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file env.h
 * \brief Header for env.c
 **/

#ifndef TOR_ENV_H
#define TOR_ENV_H

char **get_environment(void);

struct smartlist_t;

int environment_variable_names_equal(const char *s1, const char *s2);

/* DOCDOC process_environment_t */
typedef struct process_environment_t {
  /** A pointer to a sorted empty-string-terminated sequence of
   * NUL-terminated strings of the form "NAME=VALUE". */
  char *windows_environment_block;
  /** A pointer to a NULL-terminated array of pointers to
   * NUL-terminated strings of the form "NAME=VALUE". */
  char **unixoid_environment_block;
} process_environment_t;

process_environment_t *process_environment_make(struct smartlist_t *env_vars);
void process_environment_free_(process_environment_t *env);
#define process_environment_free(env) \
  FREE_AND_NULL(process_environment_t, process_environment_free_, (env))

struct smartlist_t *get_current_process_environment_variables(void);

void set_environment_variable_in_smartlist(struct smartlist_t *env_vars,
                                           const char *new_var,
                                           void (*free_old)(void*),
                                           int free_p);
#endif /* !defined(TOR_ENV_H) */
