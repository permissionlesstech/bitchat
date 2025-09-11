/* Copyright (c) 2014, Daniel Martí
 * Copyright (c) 2014-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file consdiff.h
 * @brief Header for consdiff.c
 **/

#ifndef TOR_CONSDIFF_H
#define TOR_CONSDIFF_H

#include "core/or/or.h"

char *consensus_diff_generate(const char *cons1, size_t cons1len,
                              const char *cons2, size_t cons2len);
char *consensus_diff_apply(const char *consensus, size_t consensus_len,
                           const char *diff, size_t diff_len);

int looks_like_a_consensus_diff(const char *document, size_t len);

#ifdef CONSDIFF_PRIVATE
#include "lib/container/bitarray.h"

struct memarea_t;

/** Line type used for constructing consensus diffs.  Each of these lines
 * refers to a chunk of memory allocated elsewhere, and is not necessarily
 * NUL-terminated: this helps us avoid copies and save memory. */
typedef struct cdline_t {
  const char *s;
  uint32_t len;
} cdline_t;

typedef struct consensus_digest_t {
  uint8_t sha3_256[DIGEST256_LEN];
} consensus_digest_t;

STATIC smartlist_t *consdiff_gen_diff(const smartlist_t *cons1,
                                      const smartlist_t *cons2,
                                      const consensus_digest_t *digests1,
                                      const consensus_digest_t *digests2,
                                      struct memarea_t *area);
STATIC char *consdiff_apply_diff(const smartlist_t *cons1,
                                 const smartlist_t *diff,
                                 const consensus_digest_t *digests1);
STATIC int consdiff_get_digests(const smartlist_t *diff,
                                char *digest1_out,
                                char *digest2_out);

/** Data structure to define a slice of a smarltist. */
typedef struct smartlist_slice_t {
  /**
   * Smartlist that this slice is made from.
   * References the whole original smartlist that the slice was made out of.
   * */
  const smartlist_t *list;
  /** Starting position of the slice in the smartlist. */
  int offset;
  /** Length of the slice, i.e. the number of elements it holds. */
  int len;
} smartlist_slice_t;
STATIC smartlist_t *gen_ed_diff(const smartlist_t *cons1,
                                const smartlist_t *cons2,
                                struct memarea_t *area);
STATIC smartlist_t *apply_ed_diff(const smartlist_t *cons1,
                                  const smartlist_t *diff,
                                  int start_line);
STATIC void calc_changes(smartlist_slice_t *slice1, smartlist_slice_t *slice2,
                         bitarray_t *changed1, bitarray_t *changed2);
STATIC smartlist_slice_t *smartlist_slice(const smartlist_t *list,
                                          int start, int end);
STATIC int next_router(const smartlist_t *cons, int cur);
STATIC int *lcs_lengths(const smartlist_slice_t *slice1,
                        const smartlist_slice_t *slice2,
                        int direction);
STATIC void trim_slices(smartlist_slice_t *slice1, smartlist_slice_t *slice2);
STATIC int base64cmp(const cdline_t *hash1, const cdline_t *hash2);
STATIC int get_id_hash(const cdline_t *line, cdline_t *hash_out);
STATIC int is_valid_router_entry(const cdline_t *line);
STATIC int smartlist_slice_string_pos(const smartlist_slice_t *slice,
                                      const cdline_t *string);
STATIC void set_changed(bitarray_t *changed1, bitarray_t *changed2,
                        const smartlist_slice_t *slice1,
                        const smartlist_slice_t *slice2);
STATIC int consensus_split_lines(smartlist_t *out,
                                 const char *s, size_t len,
                                 struct memarea_t *area);
STATIC void smartlist_add_linecpy(smartlist_t *lst, struct memarea_t *area,
                                  const char *s);
STATIC int lines_eq(const cdline_t *a, const cdline_t *b);
STATIC int line_str_eq(const cdline_t *a, const char *b);

MOCK_DECL(STATIC int,
          consensus_compute_digest,(const char *cons, size_t len,
                                    consensus_digest_t *digest_out));
MOCK_DECL(STATIC int,
          consensus_compute_digest_as_signed,(const char *cons, size_t len,
                                              consensus_digest_t *digest_out));
MOCK_DECL(STATIC int,
          consensus_digest_eq,(const uint8_t *d1,
                               const uint8_t *d2));
#endif /* defined(CONSDIFF_PRIVATE) */

#endif /* !defined(TOR_CONSDIFF_H) */
