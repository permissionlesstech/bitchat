/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file unparseable.h
 * \brief Header file for unparseable.c.
 **/

#ifndef TOR_UNPARSEABLE_H
#define TOR_UNPARSEABLE_H

#include "lib/cc/torint.h"

MOCK_DECL(void,dump_desc,(const char *desc, const char *type));
void dump_desc_fifo_cleanup(void);
void dump_desc_init(void);

#undef DEBUG_AREA_ALLOC
#ifdef DEBUG_AREA_ALLOC
#define DUMP_AREA(a,name) STMT_BEGIN                              \
  size_t alloc=0, used=0;                                         \
  memarea_get_stats((a),&alloc,&used);                            \
  log_debug(LD_MM, "Area for %s has %lu allocated; using %lu.",   \
            name, (unsigned long)alloc, (unsigned long)used);     \
  STMT_END
#else /* !defined(DEBUG_AREA_ALLOC) */
#define DUMP_AREA(a,name) STMT_NIL
#endif /* defined(DEBUG_AREA_ALLOC) */

#ifdef UNPARSEABLE_PRIVATE

/*
 * One entry in the list of dumped descriptors; filename dumped to, length,
 * SHA-256 and timestamp.
 */

typedef struct {
  char *filename;
  size_t len;
  uint8_t digest_sha256[DIGEST256_LEN];
  time_t when;
} dumped_desc_t;
struct smartlist_t;

EXTERN(uint64_t, len_descs_dumped)
EXTERN(struct smartlist_t *, descs_dumped)

MOCK_DECL(STATIC dumped_desc_t *, dump_desc_populate_one_file,
    (const char *dirname, const char *f));
STATIC void dump_desc_populate_fifo_from_directory(const char *dirname);
#endif /* defined(UNPARSEABLE_PRIVATE) */

#endif /* !defined(TOR_UNPARSEABLE_H) */
