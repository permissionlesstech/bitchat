/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file logic.h
 *
 * \brief Macros for comparing the boolean value of integers.
 **/

#ifndef HAVE_TOR_LOGIC_H
#define HAVE_TOR_LOGIC_H

/** Macro: true if two values have the same boolean value. */
#define bool_eq(a,b) (!(a)==!(b))
/** Macro: true if two values have different boolean values. */
#define bool_neq(a,b) (!(a)!=!(b))

#endif /* !defined(HAVE_TOR_LOGIC_H) */
