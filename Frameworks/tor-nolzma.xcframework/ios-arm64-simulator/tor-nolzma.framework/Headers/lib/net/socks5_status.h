/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file socks5_status.h
 * \brief Status codes used by the SOCKS5 protocol.
 **/

/* NOTE: it probably isn't necessary to put this header in lib/net, but
 * we need it in _some_ lower-level layer for now, since it is used by
 * tools/tor-resolve.c.
 */

#ifndef TOR_SOCKS5_STATUS_H
#define TOR_SOCKS5_STATUS_H

/** Specified SOCKS5 status codes. */
typedef enum {
  SOCKS5_SUCCEEDED                  = 0x00,
  SOCKS5_GENERAL_ERROR              = 0x01,
  SOCKS5_NOT_ALLOWED                = 0x02,
  SOCKS5_NET_UNREACHABLE            = 0x03,
  SOCKS5_HOST_UNREACHABLE           = 0x04,
  SOCKS5_CONNECTION_REFUSED         = 0x05,
  SOCKS5_TTL_EXPIRED                = 0x06,
  SOCKS5_COMMAND_NOT_SUPPORTED      = 0x07,
  SOCKS5_ADDRESS_TYPE_NOT_SUPPORTED = 0x08,

  /* Extended error code (see prop304). Only used if the SocksPort flag
   * "ExtendedErrors" is set. */
  SOCKS5_HS_NOT_FOUND               = 0xF0,
  SOCKS5_HS_IS_INVALID              = 0xF1,
  SOCKS5_HS_INTRO_FAILED            = 0xF2,
  SOCKS5_HS_REND_FAILED             = 0xF3,
  SOCKS5_HS_MISSING_CLIENT_AUTH     = 0xF4,
  SOCKS5_HS_BAD_CLIENT_AUTH         = 0xF5,
  SOCKS5_HS_BAD_ADDRESS             = 0xF6,
  SOCKS5_HS_INTRO_TIMEDOUT          = 0xF7,
} socks5_reply_status_t;

#endif /* !defined(TOR_SOCKS5_STATUS_H) */
