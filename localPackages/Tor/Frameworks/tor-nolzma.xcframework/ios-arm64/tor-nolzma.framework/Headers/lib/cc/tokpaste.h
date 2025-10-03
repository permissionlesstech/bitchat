/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file tokpaste.h
 * @brief Token-pasting macros.
 **/

#ifndef TOR_LIB_CC_TOKPASTE_H
#define TOR_LIB_CC_TOKPASTE_H

/**
 * Concatenate `a` and `b` in a way that allows their result itself to be
 * expanded by the preprocessor.
 *
 * Ordinarily you could just say `a ## b` in a macro definition.  But doing so
 * results in a symbol which the preprocessor will not then expand.  If you
 * wanted to use `a ## b` to create the name of a macro and have the
 * preprocessor expand _that_ macro, you need to have another level of
 * indirection, as this macro provides.
 **/
#define PASTE(a,b) PASTE__(a,b)

/** Helper for PASTE(). */
#define PASTE__(a,b) a ## b

#endif /* !defined(TOR_LIB_CC_TOKPASTE_H) */
