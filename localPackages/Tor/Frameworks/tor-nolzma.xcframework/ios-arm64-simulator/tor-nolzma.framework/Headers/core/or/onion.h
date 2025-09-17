/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file onion.h
 * \brief Header file for onion.c.
 **/

#ifndef TOR_ONION_H
#define TOR_ONION_H

struct create_cell_t;
struct curve25519_keypair_t;
struct curve25519_public_key_t;
#include "lib/crypt_ops/crypto_ed25519.h"

#define MAX_ONIONSKIN_CHALLENGE_LEN 255
#define MAX_ONIONSKIN_REPLY_LEN 255

/** A parsed CREATE, CREATE_FAST, or CREATE2 cell. */
typedef struct create_cell_t {
  /** The cell command. One of CREATE{,_FAST,2} */
  uint8_t cell_type;
  /** One of the ONION_HANDSHAKE_TYPE_* values */
  uint16_t handshake_type;
  /** The number of bytes used in <b>onionskin</b>. */
  uint16_t handshake_len;
  /** The client-side message for the circuit creation handshake. */
  uint8_t onionskin[CELL_PAYLOAD_SIZE - 4];
} create_cell_t;

/** A parsed CREATED, CREATED_FAST, or CREATED2 cell. */
typedef struct created_cell_t {
  /** The cell command. One of CREATED{,_FAST,2} */
  uint8_t cell_type;
  /** The number of bytes used in <b>reply</b>. */
  uint16_t handshake_len;
  /** The server-side message for the circuit creation handshake. */
  uint8_t reply[CELL_PAYLOAD_SIZE - 2];
} created_cell_t;

/** A parsed RELAY_EXTEND or RELAY_EXTEND2 cell */
typedef struct extend_cell_t {
  /** One of RELAY_EXTEND or RELAY_EXTEND2 */
  uint8_t cell_type;
  /** An IPv4 address and port for the node we're connecting to. */
  tor_addr_port_t orport_ipv4;
  /** An IPv6 address and port for the node we're connecting to. */
  tor_addr_port_t orport_ipv6;
  /** Identity fingerprint of the node we're connecting to.*/
  uint8_t node_id[DIGEST_LEN];
  /** Ed25519 public identity key. Zero if not set. */
  struct ed25519_public_key_t ed_pubkey;
  /** The "create cell" embedded in this extend cell. Note that unlike the
   * create cells we generate ourselves, this create cell can have a handshake
   * type we don't recognize. */
  create_cell_t create_cell;
} extend_cell_t;

/** A parsed RELAY_EXTEND or RELAY_EXTEND2 cell */
typedef struct extended_cell_t {
  /** One of RELAY_EXTENDED or RELAY_EXTENDED2. */
  uint8_t cell_type;
  /** The "created cell" embedded in this extended cell. */
  created_cell_t created_cell;
} extended_cell_t;

void create_cell_init(create_cell_t *cell_out, uint8_t cell_type,
                      uint16_t handshake_type, uint16_t handshake_len,
                      const uint8_t *onionskin);
int create_cell_parse(create_cell_t *cell_out, const cell_t *cell_in);
int created_cell_parse(created_cell_t *cell_out, const cell_t *cell_in);
MOCK_DECL(int,extend_cell_parse,(extend_cell_t *cell_out,
                                 const uint8_t command,
                                 const uint8_t *payload_in,
                                 size_t payload_len));
int extended_cell_parse(extended_cell_t *cell_out, const uint8_t command,
                        const uint8_t *payload_in, size_t payload_len);

int create_cell_format(cell_t *cell_out, const create_cell_t *cell_in);
int create_cell_format_relayed(cell_t *cell_out, const create_cell_t *cell_in);
int created_cell_format(cell_t *cell_out, const created_cell_t *cell_in);
int extend_cell_format(uint8_t *command_out, uint16_t *len_out,
                       uint8_t *payload_out, const extend_cell_t *cell_in);
int extended_cell_format(uint8_t *command_out, uint16_t *len_out,
                         uint8_t *payload_out, const extended_cell_t *cell_in);

#endif /* !defined(TOR_ONION_H) */
