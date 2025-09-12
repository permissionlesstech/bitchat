/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control_cmd_args_st.h
 * \brief Definition for control_cmd_args_t
 **/

#ifndef TOR_CONTROL_CMD_ST_H
#define TOR_CONTROL_CMD_ST_H

struct smartlist_t;
struct config_line_t;

/**
 * Parsed arguments for a control command.
 *
 * WORK IN PROGRESS: This structure is going to get more complex as this
 * branch goes on.
 **/
struct control_cmd_args_t {
  /**
   * The command itself, as provided by the controller.  Not owned by this
   * structure.
   **/
  const char *command;
  /**
   * Positional arguments to the command.
   **/
  struct smartlist_t *args;
  /**
   * Keyword arguments to the command.
   **/
  struct config_line_t *kwargs;
  /**
   * Number of bytes in <b>cmddata</b>; 0 if <b>cmddata</b> is not set.
   **/
  size_t cmddata_len;
  /**
   * A multiline object passed with this command.
   **/
  char *cmddata;
  /**
   * If set, a nul-terminated string containing the raw unparsed arguments.
   **/
  const char *raw_body;
};

#endif /* !defined(TOR_CONTROL_CMD_ST_H) */
