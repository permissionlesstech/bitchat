/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file socks_request_st.h
 * @brief Client request structure.
 **/

#ifndef SOCKS_REQUEST_ST_H
#define SOCKS_REQUEST_ST_H

#include "lib/net/socks5_status.h"

#define MAX_SOCKS_REPLY_LEN 1024

#define SOCKS_NO_AUTH 0x00
#define SOCKS_USER_PASS 0x02

/** Please open a TCP connection to this addr:port. */
#define SOCKS_COMMAND_CONNECT       0x01
/** Please turn this FQDN into an IP address, privately. */
#define SOCKS_COMMAND_RESOLVE       0xF0
/** Please turn this IP address into an FQDN, privately. */
#define SOCKS_COMMAND_RESOLVE_PTR   0xF1

/* || 0 is for -Wparentheses-equality (-Wall?) appeasement under clang */
#define SOCKS_COMMAND_IS_CONNECT(c) (((c)==SOCKS_COMMAND_CONNECT) || 0)
#define SOCKS_COMMAND_IS_RESOLVE(c) ((c)==SOCKS_COMMAND_RESOLVE || \
                                     (c)==SOCKS_COMMAND_RESOLVE_PTR)

/** State of a SOCKS request from a user to an OP.  Also used to encode other
 * information for non-socks user request (such as those on TransPort and
 * DNSPort) */
struct socks_request_t {
  /** Which version of SOCKS did the client use? One of "0, 4, 5" -- where
   * 0 means that no socks handshake ever took place, and this is just a
   * stub connection (e.g. see connection_ap_make_link()). */
  uint8_t socks_version;
  /** If using socks5 authentication, which authentication type did we
   * negotiate?  currently we support 0 (no authentication) and 2
   * (username/password). */
  uint8_t auth_type;
  /** What is this stream's goal? One of the SOCKS_COMMAND_* values */
  uint8_t command;
  /** Which kind of listener created this stream? */
  uint8_t listener_type;
  size_t replylen; /**< Length of <b>reply</b>. */
  uint8_t reply[MAX_SOCKS_REPLY_LEN]; /**< Write an entry into this string if
                                    * we want to specify our own socks reply,
                                    * rather than using the default socks4 or
                                    * socks5 socks reply. We use this for the
                                    * two-stage socks5 handshake.
                                    */
  char address[MAX_SOCKS_ADDR_LEN]; /**< What address did the client ask to
                                       connect to/resolve? */
  uint16_t port; /**< What port did the client ask to connect to? */
  unsigned int has_finished : 1; /**< Has the SOCKS handshake finished? Used to
                              * make sure we send back a socks reply for
                              * every connection. */
  unsigned int got_auth : 1; /**< Have we received any authentication data? */
  /** If this is set, we will choose "no authentication" instead of
   * "username/password" authentication if both are offered. Used as input to
   * parse_socks. */
  unsigned int socks_prefer_no_auth : 1;
  /** If set, we can send back the extended error code in the reply. */
  unsigned int socks_use_extended_errors : 1;
  /** If non zero, this contains the extended error code that should be used
   * if the port was configured to use them. */
  socks5_reply_status_t socks_extended_error_code;

  /** Number of bytes in username; 0 if username is NULL */
  size_t usernamelen;
  /** Number of bytes in password; 0 if password is NULL */
  uint8_t passwordlen;
  /** The negotiated username value if any (for socks5), or the entire
   * authentication string (for socks4).  This value is NOT nul-terminated;
   * see usernamelen for its length. */
  char *username;
  /** The negotiated password value if any (for socks5). This value is NOT
   * nul-terminated; see passwordlen for its length. */
  char *password;

  uint8_t socks5_atyp; /* SOCKS5 address type */
};

#endif /* !defined(SOCKS_REQUEST_ST_H) */
