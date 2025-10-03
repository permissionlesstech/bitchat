/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file files.h
 *
 * \brief Header for files.c
 **/

#ifndef TOR_FS_H
#define TOR_FS_H

#include "lib/cc/compat_compiler.h"
#include "lib/cc/torint.h"
#include "lib/testsupport/testsupport.h"

#include <stddef.h>
#include <stdio.h>

#ifdef _WIN32
/* We need these for struct stat to work */
#ifdef HAVE_SYS_TYPES_H
#include <sys/types.h>
#endif
#ifdef HAVE_SYS_STAT_H
#include <sys/stat.h>
#endif
#endif /* defined(_WIN32) */

#ifndef O_BINARY
#define O_BINARY 0
#endif
#ifndef O_TEXT
#define O_TEXT 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

struct stat;

int tor_open_cloexec(const char *path, int flags, unsigned mode);
FILE *tor_fopen_cloexec(const char *path, const char *mode);
int tor_rename(const char *path_old, const char *path_new);

int replace_file(const char *from, const char *to);
int touch_file(const char *fname);

MOCK_DECL(int,tor_unlink,(const char *pathname));

/** Return values from file_status(); see that function's documentation
 * for details. */
typedef enum { FN_ERROR, FN_NOENT, FN_FILE, FN_DIR, FN_EMPTY } file_status_t;

file_status_t file_status(const char *filename);
bool is_file(file_status_t file_type);
bool is_dir(file_status_t file_type);

int64_t tor_get_avail_disk_space(const char *path);

ssize_t write_all_to_fd(int fd, const char *buf, size_t count);
ssize_t read_all_from_fd(int fd, char *buf, size_t count);

#define OPEN_FLAGS_REPLACE (O_WRONLY|O_CREAT|O_TRUNC)
#define OPEN_FLAGS_APPEND (O_WRONLY|O_CREAT|O_APPEND)
#define OPEN_FLAGS_DONT_REPLACE (O_CREAT|O_EXCL|O_APPEND|O_WRONLY)
typedef struct open_file_t open_file_t;
int start_writing_to_file(const char *fname, int open_flags, int mode,
                          open_file_t **data_out);
FILE *start_writing_to_stdio_file(const char *fname, int open_flags, int mode,
                                  open_file_t **data_out);
FILE *fdopen_file(open_file_t *file_data);
int finish_writing_to_file(open_file_t *file_data);
int abort_writing_to_file(open_file_t *file_data);
MOCK_DECL(int, write_str_to_file,(const char *fname, const char *str,
                                  int bin));
MOCK_DECL(int, write_bytes_to_file,(const char *fname, const char *str,
                                    size_t len,int bin));

/** An ad-hoc type to hold a string of characters and a count; used by
 * write_chunks_to_file. */
typedef struct sized_chunk_t {
  const char *bytes;
  size_t len;
} sized_chunk_t;
struct smartlist_t;
int write_chunks_to_file(const char *fname, const struct smartlist_t *chunks,
                         int bin, int no_tempfile);
int append_bytes_to_file(const char *fname, const char *str, size_t len,
                         int bin);
int write_bytes_to_new_file(const char *fname, const char *str, size_t len,
                            int bin);

int write_str_to_file_if_not_equal(const char *fname, const char *str);

/** Flag for read_file_to_str: open the file in binary mode. */
#define RFTS_BIN            1
/** Flag for read_file_to_str: it's okay if the file doesn't exist. */
#define RFTS_IGNORE_MISSING 2

MOCK_DECL_ATTR(char *, read_file_to_str,(const char *filename, int flags,
                                         struct stat *stat_out),
               ATTR_MALLOC);
char *read_file_to_str_until_eof(int fd, size_t max_bytes_to_read,
                                 size_t *sz_out)
  ATTR_MALLOC;

#if !defined(HAVE_GETDELIM) || defined(TOR_UNIT_TESTS)
/** Internal back-end function to implement getdelim(): only exists when
 * Tor is built for unit tests, or when Tor is built on an operating system
 * without its own getdelim(). */
ssize_t compat_getdelim_(char **lineptr, size_t *n, int delim, FILE *stream);
#endif /* !defined(HAVE_GETDELIM) || defined(TOR_UNIT_TESTS) */

#ifdef HAVE_GETDELIM
/**
 * Cross-platform wrapper for getdelim(): behaves as the POSIX-standard
 * getdelim() function.
 *
 * See `getdelim(3)` for more information.
 *
 * Note that this function will use the libc memory allocator -- so any memory
 * passed to this function must come from raw_malloc(), and must be freed by
 * raw_free() -- don't use tor_malloc() and tor_free() with this.
 */
#define tor_getdelim(lineptr, n, delim, stream) \
  getdelim((lineptr), (n), (delim), (stream))
#else /* !defined(HAVE_GETDELIM) */
#define tor_getdelim(lineptr, n, delim, stream) \
  compat_getdelim_((lineptr), (n), (delim), (stream))
#endif /* defined(HAVE_GETDELIM) */

#ifdef HAVE_GETLINE
/**
 * Cross-platform wrapper for getline(): behaves as the POSIX-standard
 * getline() function.
 *
 * See tor_getdelim() for usage notes.
 */
#define tor_getline(lineptr, n, stream) \
  getline((lineptr), (n), (stream))
#else /* !defined(HAVE_GETLINE) */
#define tor_getline(lineptr, n, stream) \
  tor_getdelim((lineptr), (n), '\n', (stream))
#endif /* defined(HAVE_GETLINE) */

#endif /* !defined(TOR_FS_H) */
