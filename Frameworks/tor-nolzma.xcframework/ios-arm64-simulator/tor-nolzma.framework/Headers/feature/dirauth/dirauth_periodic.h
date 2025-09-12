/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file dirauth_periodic.h
 * @brief Header for dirauth_periodic.c
 **/

#ifndef DIRVOTE_PERIODIC_H
#define DIRVOTE_PERIODIC_H

#ifdef HAVE_MODULE_DIRAUTH

void dirauth_register_periodic_events(void);
void reschedule_dirvote(const or_options_t *options);

#else /* !defined(HAVE_MODULE_DIRAUTH) */

static inline void
reschedule_dirvote(const or_options_t *options)
{
  (void)options;
}

#endif /* defined(HAVE_MODULE_DIRAUTH) */

#endif /* !defined(DIRVOTE_PERIODIC_H) */
