/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file process.h
 * \brief Header for process.c
 **/

#ifndef TOR_PROCESS_H
#define TOR_PROCESS_H

#include "orconfig.h"
#include "lib/malloc/malloc.h"
#include "lib/string/printf.h"

#include <stdbool.h>

/** Maximum number of bytes to write to a process' stdin. */
#define PROCESS_MAX_WRITE (1024)

/** Maximum number of bytes to read from a process' stdout/stderr. */
#define PROCESS_MAX_READ  (1024)

typedef enum {
  /** The process is not running. */
  PROCESS_STATUS_NOT_RUNNING,

  /** The process is running. */
  PROCESS_STATUS_RUNNING,

  /** The process is in an erroneous state. */
  PROCESS_STATUS_ERROR
} process_status_t;

const char *process_status_to_string(process_status_t status);

typedef enum {
  /** Pass complete newline-terminated lines to the
   *  callback (with the LF or CRLF removed). */
  PROCESS_PROTOCOL_LINE,

  /** Pass the raw response from read() to the callback. */
  PROCESS_PROTOCOL_RAW
} process_protocol_t;

const char *process_protocol_to_string(process_protocol_t protocol);

void tor_disable_spawning_background_processes(void);

struct smartlist_t;

struct process_t;
typedef struct process_t process_t;

typedef uint64_t process_exit_code_t;
typedef uint64_t process_pid_t;

typedef void (*process_read_callback_t)(process_t *,
                                        const char *,
                                        size_t);
typedef bool
(*process_exit_callback_t)(process_t *, process_exit_code_t);

void process_init(void);
void process_free_all(void);
const struct smartlist_t *process_get_all_processes(void);

process_t *process_new(const char *command);
void process_free_(process_t *process);
#define process_free(s) FREE_AND_NULL(process_t, process_free_, (s))

process_status_t process_exec(process_t *process);
bool process_terminate(process_t *process);

process_pid_t process_get_pid(process_t *process);

void process_set_stdout_read_callback(process_t *,
                                      process_read_callback_t);
void process_set_stderr_read_callback(process_t *,
                                      process_read_callback_t);
void process_set_exit_callback(process_t *,
                               process_exit_callback_t);

const char *process_get_command(const process_t *process);

void process_append_argument(process_t *process, const char *argument);
const struct smartlist_t *process_get_arguments(const process_t *process);
char **process_get_argv(const process_t *process);

void process_reset_environment(process_t *process,
                               const struct smartlist_t *env);
void process_set_environment(process_t *process,
                             const char *key,
                             const char *value);

struct process_environment_t;
struct process_environment_t *process_get_environment(const process_t *);

void process_set_protocol(process_t *process, process_protocol_t protocol);
process_protocol_t process_get_protocol(const process_t *process);

void process_set_data(process_t *process, void *data);
void *process_get_data(const process_t *process);

void process_set_status(process_t *process, process_status_t status);
process_status_t process_get_status(const process_t *process);

#ifndef _WIN32
struct process_unix_t;
struct process_unix_t *process_get_unix_process(const process_t *process);
#else
struct process_win32_t;
struct process_win32_t *process_get_win32_process(const process_t *process);
#endif /* !defined(_WIN32) */

void process_write(process_t *process,
                   const uint8_t *data, size_t size);
void process_vprintf(process_t *process,
                     const char *format, va_list args) CHECK_PRINTF(2, 0);
void process_printf(process_t *process,
                    const char *format, ...) CHECK_PRINTF(2, 3);

void process_notify_event_stdout(process_t *process);
void process_notify_event_stderr(process_t *process);
void process_notify_event_stdin(process_t *process);
void process_notify_event_exit(process_t *process,
                               process_exit_code_t);

#ifdef PROCESS_PRIVATE
struct buf_t;
MOCK_DECL(STATIC int, process_read_stdout, (process_t *, struct buf_t *));
MOCK_DECL(STATIC int, process_read_stderr, (process_t *, struct buf_t *));
MOCK_DECL(STATIC void, process_write_stdin, (process_t *, struct buf_t *));

STATIC void process_read_data(process_t *process,
                              struct buf_t *buffer,
                              process_read_callback_t callback);
STATIC void process_read_buffer(process_t *process,
                                struct buf_t *buffer,
                                process_read_callback_t callback);
STATIC void process_read_lines(process_t *process,
                               struct buf_t *buffer,
                               process_read_callback_t callback);
#endif /* defined(PROCESS_PRIVATE) */

#endif /* !defined(TOR_PROCESS_H) */
