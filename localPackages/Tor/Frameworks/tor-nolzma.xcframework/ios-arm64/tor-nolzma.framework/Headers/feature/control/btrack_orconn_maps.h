/* Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file btrack_orconn_maps.h
 * \brief Header file for btrack_orconn_maps.c
 **/

#ifndef TOR_BTRACK_ORCONN_MAPS_H
#define TOR_BTRACK_ORCONN_MAPS_H

void bto_delete(uint64_t);
bt_orconn_t *bto_find_or_new(uint64_t, uint64_t);

void bto_init_maps(void);
void bto_clear_maps(void);

#endif /* !defined(TOR_BTRACK_ORCONN_MAPS_H) */
