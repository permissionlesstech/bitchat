 /* Copyright (c) 2014-2021, The Tor Project, Inc. */
 /* See LICENSE for licensing information */

#ifndef TOR_FAKECHANS_H
#define TOR_FAKECHANS_H

/**
 * \file fakechans.h
 * \brief Declarations for fake channels for test suite use
 */

void make_fake_cell(cell_t *c);
void make_fake_var_cell(var_cell_t *c);
channel_t * new_fake_channel(void);
void free_fake_channel(channel_t *c);

/* Also exposes some a mock used by both test_channel.c and test_relay.c */
void scheduler_channel_has_waiting_cells_mock(channel_t *ch);
void scheduler_release_channel_mock(channel_t *ch);

/* Query some counters used by the exposed mocks */
int get_mock_scheduler_has_waiting_cells_count(void);

#endif /* !defined(TOR_FAKECHANS_H) */

