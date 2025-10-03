/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file fakecircs.h
 * \brief Declarations for fake circuits for test suite use.
 **/

#ifndef TOR_FAKECIRCS_H
#define TOR_FAKECIRCS_H

#include "core/or/or_circuit_st.h"

or_circuit_t *new_fake_orcirc(channel_t *nchan, channel_t *pchan);
void free_fake_orcirc(or_circuit_t *orcirc);

#endif /* !defined(TOR_FAKECIRCS_H) */
