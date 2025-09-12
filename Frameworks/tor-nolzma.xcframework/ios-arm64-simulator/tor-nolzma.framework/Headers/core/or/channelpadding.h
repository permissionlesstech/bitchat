/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file circuitbuild.h
 * \brief Header file for circuitbuild.c.
 **/
#ifndef TOR_CHANNELPADDING_H
#define TOR_CHANNELPADDING_H

#include "trunnel/channelpadding_negotiation.h"

#define CHANNELPADDING_SOS_PARAM  "nf_pad_single_onion"
#define CHANNELPADDING_SOS_DEFAULT 1

typedef enum {
  CHANNELPADDING_WONTPAD,
  CHANNELPADDING_PADLATER,
  CHANNELPADDING_PADDING_SCHEDULED,
  CHANNELPADDING_PADDING_ALREADY_SCHEDULED,
  CHANNELPADDING_PADDING_SENT,
} channelpadding_decision_t;

channelpadding_decision_t channelpadding_decide_to_pad_channel(channel_t
                                                               *chan);
int channelpadding_update_padding_for_channel(channel_t *,
                                              const channelpadding_negotiate_t
                                              *chan);

void channelpadding_disable_padding_on_channel(channel_t *chan);
void channelpadding_reduce_padding_on_channel(channel_t *chan);
int channelpadding_send_enable_command(channel_t *chan, uint16_t low_timeout,
                                       uint16_t high_timeout);

int channelpadding_get_circuits_available_timeout(void);
unsigned int channelpadding_get_channel_idle_timeout(const channel_t *, int);
void channelpadding_new_consensus_params(const networkstatus_t *ns);

#endif /* !defined(TOR_CHANNELPADDING_H) */
