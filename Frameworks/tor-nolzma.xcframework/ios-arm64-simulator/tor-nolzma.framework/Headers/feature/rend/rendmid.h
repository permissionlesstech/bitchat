/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file rendmid.h
 * \brief Header file for rendmid.c.
 **/

#ifndef TOR_RENDMID_H
#define TOR_RENDMID_H

int rend_mid_establish_intro_legacy(or_circuit_t *circ, const uint8_t *request,
                                    size_t request_len);
int rend_mid_introduce_legacy(or_circuit_t *circ, const uint8_t *request,
                              size_t request_len);
int rend_mid_establish_rendezvous(or_circuit_t *circ, const uint8_t *request,
                                  size_t request_len);
int rend_mid_rendezvous(or_circuit_t *circ, const uint8_t *request,
                        size_t request_len);

#endif /* !defined(TOR_RENDMID_H) */

