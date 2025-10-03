/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file process_win32.h
 * \brief Header for process_win32.c
 **/

#ifndef TOR_PROCESS_WIN32_H
#define TOR_PROCESS_WIN32_H

#ifdef _WIN32

#include "orconfig.h"
#include "lib/malloc/malloc.h"
#include "lib/evloop/compat_libevent.h"

#include <windows.h>

struct process_t;

struct process_win32_t;
typedef struct process_win32_t process_win32_t;

process_win32_t *process_win32_new(void);
void process_win32_free_(process_win32_t *win32_process);
#define process_win32_free(s) \
  FREE_AND_NULL(process_win32_t, process_win32_free_, (s))

void process_win32_init(void);
void process_win32_deinit(void);

process_status_t process_win32_exec(struct process_t *process);
bool process_win32_terminate(struct process_t *process);

process_pid_t process_win32_get_pid(struct process_t *process);

int process_win32_write(struct process_t *process, buf_t *buffer);
int process_win32_read_stdout(struct process_t *process, buf_t *buffer);
int process_win32_read_stderr(struct process_t *process, buf_t *buffer);

void process_win32_trigger_completion_callbacks(void);

/* Timer handling. */
void process_win32_timer_start(void);
void process_win32_timer_stop(void);
bool process_win32_timer_running(void);

#ifdef PROCESS_WIN32_PRIVATE
STATIC void process_win32_timer_callback(periodic_timer_t *, void *);
STATIC bool process_win32_timer_test_process(process_t *);

/* I/O pipe handling. */
struct process_win32_handle_t;
typedef struct process_win32_handle_t process_win32_handle_t;

typedef enum process_win32_pipe_type_t {
  /** This pipe is used for reading. */
  PROCESS_WIN32_PIPE_TYPE_READER,

  /** This pipe is used for writing. */
  PROCESS_WIN32_PIPE_TYPE_WRITER
} process_win32_pipe_type_t;

STATIC bool process_win32_create_pipe(HANDLE *,
                                      HANDLE *,
                                      SECURITY_ATTRIBUTES *,
                                      process_win32_pipe_type_t);

STATIC void process_win32_cleanup_handle(process_win32_handle_t *handle);

STATIC VOID WINAPI process_win32_stdout_read_done(DWORD,
                                                  DWORD,
                                                  LPOVERLAPPED);
STATIC VOID WINAPI process_win32_stderr_read_done(DWORD,
                                                  DWORD,
                                                  LPOVERLAPPED);
STATIC VOID WINAPI process_win32_stdin_write_done(DWORD,
                                                  DWORD,
                                                  LPOVERLAPPED);

STATIC int process_win32_read_from_handle(process_win32_handle_t *,
                                          buf_t *,
                                          LPOVERLAPPED_COMPLETION_ROUTINE);
STATIC bool process_win32_handle_read_completion(process_win32_handle_t *,
                                                 DWORD,
                                                 DWORD);

STATIC char *format_win_cmdline_argument(const char *arg);
STATIC char *tor_join_win_cmdline(const char *argv[]);
#endif /* defined(PROCESS_WIN32_PRIVATE) */

#endif /* defined(_WIN32) */

#endif /* !defined(TOR_PROCESS_WIN32_H) */
