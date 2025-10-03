/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file var_cell_st.h
 * @brief Variable-length cell structure.
 **/

#ifndef VAR_CELL_ST_H
#define VAR_CELL_ST_H

/** Parsed variable-length onion routing cell. */
struct var_cell_t {
  /** Type of the cell: CELL_VERSIONS, etc. */
  uint8_t command;
  /** Circuit thich received the cell */
  circid_t circ_id;
  /** Number of bytes actually stored in <b>payload</b> */
  uint16_t payload_len;
  /** Payload of this cell */
  uint8_t payload[FLEXIBLE_ARRAY_MEMBER];
};

#endif /* !defined(VAR_CELL_ST_H) */
