/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file control_proto.h
 * \brief Header file for control_proto.c.
 *
 * See @ref replylines for details about the key-value abstraction for
 * generating reply lines.
 **/

#ifndef TOR_CONTROL_PROTO_H
#define TOR_CONTROL_PROTO_H

#include "lib/encoding/confline.h"

/**
 * @defgroup replylines Control reply lines
 * @brief Key-value structures for control reply lines
 *
 * Control reply lines are config_line_t key-value structures with
 * some additional information to help formatting, such as the numeric
 * result code specified in the control protocol and flags affecting
 * the way kvline_encode() formats the @a kvline.
 *
 * Generally, modules implementing control commands will work with
 * smartlists of these structures, using functions like
 * control_reply_add_str() for adding a reply line consisting of a
 * single string, or control_reply_add_one_kv() and
 * control_reply_append_kv() for composing a line containing one or
 * more key-value pairs.
 *
 * @{
 */
/** @brief A reply line for the control protocol.
 *
 * This wraps config_line_t with some additional information that's
 * useful when generating control reply lines.
 */
typedef struct control_reply_line_t {
  int code;                     /**< numeric code */
  int flags;                    /**< kvline encoding flags */
  config_line_t *kvline;        /**< kvline */
} control_reply_line_t;

void control_reply_line_free_(control_reply_line_t *line);
/**
 * @brief Free and null a control_reply_line_t
 *
 * @param line pointer to control_reply_line_t to free
 */
#define control_reply_line_free(line)                   \
  FREE_AND_NULL(control_reply_line_t,                   \
                control_reply_line_free_, (line))
/** @} */

void connection_write_str_to_buf(const char *s, control_connection_t *conn);
void connection_printf_to_buf(control_connection_t *conn,
                                     const char *format, ...)
  CHECK_PRINTF(2,3);

size_t write_escaped_data(const char *data, size_t len, char **out);
size_t read_escaped_data(const char *data, size_t len, char **out);
void send_control_done(control_connection_t *conn);

MOCK_DECL(void, control_write_reply, (control_connection_t *conn, int code,
                                      int c, const char *s));
void control_vprintf_reply(control_connection_t *conn, int code, int c,
                           const char *fmt, va_list ap)
  CHECK_PRINTF(4, 0);
void control_write_endreply(control_connection_t *conn, int code,
                            const char *s);
void control_printf_endreply(control_connection_t *conn, int code,
                             const char *fmt, ...)
  CHECK_PRINTF(3, 4);
void control_write_midreply(control_connection_t *conn, int code,
                            const char *s);
void control_printf_midreply(control_connection_t *conn, int code,
                             const char *fmt,
                             ...)
  CHECK_PRINTF(3, 4);
void control_write_datareply(control_connection_t *conn, int code,
                             const char *s);
void control_printf_datareply(control_connection_t *conn, int code,
                              const char *fmt,
                              ...)
  CHECK_PRINTF(3, 4);
void control_write_data(control_connection_t *conn, const char *data);

/** @addtogroup replylines
 * @{
 */
void control_write_reply_line(control_connection_t *conn,
                              const control_reply_line_t *line, bool lastone);
void control_write_reply_lines(control_connection_t *conn, smartlist_t *lines);

void control_reply_add_one_kv(smartlist_t *reply, int code, int flags,
                              const char *key, const char *val);
void control_reply_append_kv(smartlist_t *reply, const char *key,
                             const char *val);
void control_reply_add_str(smartlist_t *reply, int code, const char *s);
void control_reply_add_printf(smartlist_t *reply, int code,
                              const char *fmt, ...)
  CHECK_PRINTF(3, 4);
void control_reply_add_done(smartlist_t *reply);

void control_reply_clear(smartlist_t *reply);
void control_reply_free_(smartlist_t *reply);

/** @brief Free and null a smartlist of control_reply_line_t.
 *
 * @param r pointer to smartlist_t of control_reply_line_t to free */
#define control_reply_free(r) \
  FREE_AND_NULL(smartlist_t, control_reply_free_, (r))
/** @} */

#endif /* !defined(TOR_CONTROL_PROTO_H) */
