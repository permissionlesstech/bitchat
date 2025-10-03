/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file command.h
 * \brief Header file for command.c.
 **/

#ifndef TOR_COMMAND_H
#define TOR_COMMAND_H

#include "core/or/channel.h"

void command_process_cell(channel_t *chan, cell_t *cell);
void command_setup_channel(channel_t *chan);
void command_setup_listener(channel_listener_t *chan_l);

const char *cell_command_to_string(uint8_t command);

extern uint64_t stats_n_padding_cells_processed;
extern uint64_t stats_n_create_cells_processed;
extern uint64_t stats_n_created_cells_processed;
extern uint64_t stats_n_relay_cells_processed;
extern uint64_t stats_n_destroy_cells_processed;

#endif /* !defined(TOR_COMMAND_H) */

