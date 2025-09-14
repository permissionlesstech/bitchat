/* Copyright (c) 2003, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file laplace.h
 *
 * \brief Header for laplace.c
 **/

#ifndef TOR_LAPLACE_H
#define TOR_LAPLACE_H

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"

int64_t sample_laplace_distribution(double mu, double b, double p);
int64_t add_laplace_noise(int64_t signal, double random, double delta_f,
                          double epsilon);

#endif /* !defined(TOR_LAPLACE_H) */
