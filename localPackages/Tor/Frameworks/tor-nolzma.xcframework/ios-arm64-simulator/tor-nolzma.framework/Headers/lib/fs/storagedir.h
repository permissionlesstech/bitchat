/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file storagedir.h
 *
 * \brief Header for storagedir.c
 **/

#ifndef TOR_STORAGEDIR_H
#define TOR_STORAGEDIR_H

#include "lib/cc/torint.h"
#include <stddef.h>

typedef struct storage_dir_t storage_dir_t;
struct config_line_t;
struct sandbox_cfg_elem_t;
struct tor_mmap_t;
struct smartlist_t;

storage_dir_t * storage_dir_new(const char *dirname, int n_files);
void storage_dir_free_(storage_dir_t *d);
#define storage_dir_free(d) \
  FREE_AND_NULL(storage_dir_t, storage_dir_free_, (d))

int storage_dir_register_with_sandbox(storage_dir_t *d,
                                      struct sandbox_cfg_elem_t **cfg);
const struct smartlist_t *storage_dir_list(storage_dir_t *d);
uint64_t storage_dir_get_usage(storage_dir_t *d);
struct tor_mmap_t *storage_dir_map(storage_dir_t *d, const char *fname);
uint8_t *storage_dir_read(storage_dir_t *d, const char *fname, int bin,
                          size_t *sz_out);
int storage_dir_save_bytes_to_file(storage_dir_t *d,
                                   const uint8_t *data,
                                   size_t length,
                                   int binary,
                                   char **fname_out);
int storage_dir_save_string_to_file(storage_dir_t *d,
                                    const char *data,
                                    int binary,
                                    char **fname_out);
int storage_dir_save_labeled_to_file(storage_dir_t *d,
                                      const struct config_line_t *labels,
                                      const uint8_t *data,
                                      size_t length,
                                      char **fname_out);
struct tor_mmap_t *storage_dir_map_labeled(storage_dir_t *dir,
                                     const char *fname,
                                     struct config_line_t **labels_out,
                                     const uint8_t **data_out,
                                     size_t *size_out);
uint8_t *storage_dir_read_labeled(storage_dir_t *d, const char *fname,
                                   struct config_line_t **labels_out,
                                   size_t *sz_out);
void storage_dir_remove_file(storage_dir_t *d,
                             const char *fname);
int storage_dir_shrink(storage_dir_t *d,
                       uint64_t target_size,
                       int min_to_remove);
int storage_dir_remove_all(storage_dir_t *d);
int storage_dir_get_max_files(storage_dir_t *d);

#endif /* !defined(TOR_STORAGEDIR_H) */
