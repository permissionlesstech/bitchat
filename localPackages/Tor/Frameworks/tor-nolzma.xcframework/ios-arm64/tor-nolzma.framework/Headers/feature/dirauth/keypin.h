/* Copyright (c) 2014-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file keypin.h
 * @brief Header for keypin.c
 **/

#ifndef TOR_KEYPIN_H
#define TOR_KEYPIN_H

#include "lib/testsupport/testsupport.h"

int keypin_check_and_add(const uint8_t *rsa_id_digest,
                         const uint8_t *ed25519_id_key,
                         const int replace_existing_entry);
int keypin_check(const uint8_t *rsa_id_digest,
                 const uint8_t *ed25519_id_key);
int keypin_close_journal(void);

#ifdef HAVE_MODULE_DIRAUTH
int keypin_open_journal(const char *fname);
int keypin_load_journal(const char *fname);
#else
static inline int
keypin_open_journal(const char *fname)
{
  (void)fname;
  return 0;
}
static inline int
keypin_load_journal(const char *fname)
{
  (void)fname;
  return 0;
}
#endif /* defined(HAVE_MODULE_DIRAUTH) */
void keypin_clear(void);
int keypin_check_lone_rsa(const uint8_t *rsa_id_digest);

#define KEYPIN_FOUND 0
#define KEYPIN_ADDED 1
#define KEYPIN_MISMATCH -1
#define KEYPIN_NOT_FOUND -2

#ifdef KEYPIN_PRIVATE

#include "ext/ht.h"

/**
 * In-memory representation of a key-pinning table entry.
 */
typedef struct keypin_ent_st {
  HT_ENTRY(keypin_ent_st) rsamap_node;
  HT_ENTRY(keypin_ent_st) edmap_node;
  /** SHA1 hash of the RSA key */
  uint8_t rsa_id[DIGEST_LEN];
  /** Ed2219 key. */
  uint8_t ed25519_key[DIGEST256_LEN];
} keypin_ent_t;

STATIC keypin_ent_t * keypin_parse_journal_line(const char *cp);
STATIC int keypin_load_journal_impl(const char *data, size_t size);

MOCK_DECL(STATIC void, keypin_add_entry_to_map, (keypin_ent_t *ent));
#endif /* defined(KEYPIN_PRIVATE) */

#endif /* !defined(TOR_KEYPIN_H) */
