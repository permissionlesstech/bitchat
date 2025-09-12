/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file ntmain.h
 * \brief Header file for ntmain.c.
 **/

#ifndef TOR_NTMAIN_H
#define TOR_NTMAIN_H

#ifdef _WIN32
#define NT_SERVICE
#endif

#ifdef NT_SERVICE
int nt_service_parse_options(int argc, char **argv, int *should_exit);
int nt_service_is_stopping(void);
void nt_service_set_state(DWORD state);
#else
#define nt_service_is_stopping() 0
#define nt_service_parse_options(a, b, c) (0)
#define nt_service_set_state(s) STMT_NIL
#endif /* defined(NT_SERVICE) */

#endif /* !defined(TOR_NTMAIN_H) */
