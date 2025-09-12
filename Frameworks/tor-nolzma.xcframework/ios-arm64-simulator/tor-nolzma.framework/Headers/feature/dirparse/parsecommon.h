/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file parsecommon.h
 * \brief Header file for parsecommon.c
 **/

#ifndef TOR_PARSECOMMON_H
#define TOR_PARSECOMMON_H

#include <stddef.h>

struct smartlist_t;
struct crypto_pk_t;
struct memarea_t;

/** Enumeration of possible token types.  The ones starting with K_ correspond
* to directory 'keywords'. A_ is for an annotation, R or C is related to
* hidden services, ERR_ is an error in the tokenizing process, EOF_ is an
* end-of-file marker, and NIL_ is used to encode not-a-token.
*/
typedef enum {
  K_ACCEPT = 0,
  K_ACCEPT6,
  K_DIRECTORY_SIGNATURE,
  K_RECOMMENDED_SOFTWARE,
  K_REJECT,
  K_REJECT6,
  K_ROUTER,
  K_SIGNED_DIRECTORY,
  K_SIGNING_KEY,
  K_ONION_KEY,
  K_ONION_KEY_NTOR,
  K_ROUTER_SIGNATURE,
  K_PUBLISHED,
  K_RUNNING_ROUTERS,
  K_ROUTER_STATUS,
  K_PLATFORM,
  K_PROTO,
  K_OPT,
  K_BANDWIDTH,
  K_CONTACT,
  K_NETWORK_STATUS,
  K_UPTIME,
  K_DIR_SIGNING_KEY,
  K_FAMILY,
  K_FINGERPRINT,
  K_HIBERNATING,
  K_READ_HISTORY,
  K_WRITE_HISTORY,
  K_NETWORK_STATUS_VERSION,
  K_DIR_SOURCE,
  K_DIR_OPTIONS,
  K_CLIENT_VERSIONS,
  K_SERVER_VERSIONS,
  K_RECOMMENDED_CLIENT_PROTOCOLS,
  K_RECOMMENDED_RELAY_PROTOCOLS,
  K_REQUIRED_CLIENT_PROTOCOLS,
  K_REQUIRED_RELAY_PROTOCOLS,
  K_OR_ADDRESS,
  K_ID,
  K_P,
  K_P6,
  K_R,
  K_A,
  K_S,
  K_V,
  K_W,
  K_M,
  K_EXTRA_INFO,
  K_EXTRA_INFO_DIGEST,
  K_CACHES_EXTRA_INFO,
  K_HIDDEN_SERVICE_DIR,
  K_ALLOW_SINGLE_HOP_EXITS,
  K_IPV6_POLICY,
  K_ROUTER_SIG_ED25519,
  K_IDENTITY_ED25519,
  K_MASTER_KEY_ED25519,
  K_ONION_KEY_CROSSCERT,
  K_NTOR_ONION_KEY_CROSSCERT,

  K_DIRREQ_END,
  K_DIRREQ_V2_IPS,
  K_DIRREQ_V3_IPS,
  K_DIRREQ_V2_REQS,
  K_DIRREQ_V3_REQS,
  K_DIRREQ_V2_SHARE,
  K_DIRREQ_V3_SHARE,
  K_DIRREQ_V2_RESP,
  K_DIRREQ_V3_RESP,
  K_DIRREQ_V2_DIR,
  K_DIRREQ_V3_DIR,
  K_DIRREQ_V2_TUN,
  K_DIRREQ_V3_TUN,
  K_ENTRY_END,
  K_ENTRY_IPS,
  K_CELL_END,
  K_CELL_PROCESSED,
  K_CELL_QUEUED,
  K_CELL_TIME,
  K_CELL_CIRCS,
  K_EXIT_END,
  K_EXIT_WRITTEN,
  K_EXIT_READ,
  K_EXIT_OPENED,

  K_DIR_KEY_CERTIFICATE_VERSION,
  K_DIR_IDENTITY_KEY,
  K_DIR_KEY_PUBLISHED,
  K_DIR_KEY_EXPIRES,
  K_DIR_KEY_CERTIFICATION,
  K_DIR_KEY_CROSSCERT,
  K_DIR_ADDRESS,
  K_DIR_TUNNELLED,

  K_VOTE_STATUS,
  K_VALID_AFTER,
  K_FRESH_UNTIL,
  K_VALID_UNTIL,
  K_VOTING_DELAY,

  K_KNOWN_FLAGS,
  K_PARAMS,
  K_BW_WEIGHTS,
  K_VOTE_DIGEST,
  K_CONSENSUS_DIGEST,
  K_ADDITIONAL_DIGEST,
  K_ADDITIONAL_SIGNATURE,
  K_CONSENSUS_METHODS,
  K_CONSENSUS_METHOD,
  K_LEGACY_DIR_KEY,
  K_DIRECTORY_FOOTER,
  K_SIGNING_CERT_ED,
  K_SR_FLAG,
  K_COMMIT,
  K_PREVIOUS_SRV,
  K_CURRENT_SRV,
  K_PACKAGE,

  A_PURPOSE,
  A_LAST_LISTED,
  A_UNKNOWN_,

  R_RENDEZVOUS_SERVICE_DESCRIPTOR,
  R_VERSION,
  R_PERMANENT_KEY,
  R_SECRET_ID_PART,
  R_PUBLICATION_TIME,
  R_PROTOCOL_VERSIONS,
  R_INTRODUCTION_POINTS,
  R_SIGNATURE,

  R_HS_DESCRIPTOR, /* From version 3, this MUST be generic to all future
                      descriptor versions thus making it R_. */
  R3_DESC_LIFETIME,
  R3_DESC_SIGNING_CERT,
  R3_REVISION_COUNTER,
  R3_SUPERENCRYPTED,
  R3_SIGNATURE,
  R3_CREATE2_FORMATS,
  R3_INTRO_AUTH_REQUIRED,
  R3_SINGLE_ONION_SERVICE,
  R3_INTRODUCTION_POINT,
  R3_INTRO_ONION_KEY,
  R3_INTRO_AUTH_KEY,
  R3_INTRO_ENC_KEY,
  R3_INTRO_ENC_KEY_CERT,
  R3_INTRO_LEGACY_KEY,
  R3_INTRO_LEGACY_KEY_CERT,
  R3_DESC_AUTH_TYPE,
  R3_DESC_AUTH_KEY,
  R3_DESC_AUTH_CLIENT,
  R3_ENCRYPTED,
  R3_FLOW_CONTROL,
  R3_POW_PARAMS,

  R_IPO_IDENTIFIER,
  R_IPO_IP_ADDRESS,
  R_IPO_ONION_PORT,
  R_IPO_ONION_KEY,
  R_IPO_SERVICE_KEY,

  C_CLIENT_NAME,
  C_DESCRIPTOR_COOKIE,
  C_CLIENT_KEY,

  ERR_,
  EOF_,
  NIL_
} directory_keyword;

/** Structure to hold a single directory token.
 *
 * We parse a directory by breaking it into "tokens", each consisting
 * of a keyword, a line full of arguments, and a binary object.  The
 * arguments and object are both optional, depending on the keyword
 * type.
 *
 * This structure is only allocated in memareas; do not allocate it on
 * the heap, or token_clear() won't work.
 */
typedef struct directory_token_t {
  directory_keyword tp;        /**< Type of the token. */
  int n_args:30;               /**< Number of elements in args */
  char **args;                 /**< Array of arguments from keyword line. */

  char *object_type;           /**< -----BEGIN [object_type]-----*/
  size_t object_size;          /**< Bytes in object_body */
  char *object_body;           /**< Contents of object, base64-decoded. */

  struct crypto_pk_t *key;     /**< For public keys only.  Heap-allocated. */

  char *error;                 /**< For ERR_ tokens only. */
} directory_token_t;

/** We use a table of rules to decide how to parse each token type. */

/** Rules for whether the keyword needs an object. */
typedef enum {
  NO_OBJ,        /**< No object, ever. */
  NEED_OBJ,      /**< Object is required. */
  NEED_KEY_1024, /**< Object is required, and must be a 1024 bit public key */
  NEED_KEY,      /**< Object is required, and must be a public key. */
  OBJ_OK,        /**< Object is optional. */
} obj_syntax;

#define AT_START 1
#define AT_END 2

#define TS_ANNOTATIONS_OK 1
#define TS_NOCHECK 2
#define TS_NO_NEW_ANNOTATIONS 4

/**
 * @name macros for defining token rules
 *
 * Helper macros to define token tables.  's' is a string, 't' is a
 * directory_keyword, 'a' is a trio of argument multiplicities, and 'o' is an
 * object syntax.
 */
/**@{*/

/** Appears to indicate the end of a table. */
#define END_OF_TABLE { NULL, NIL_, 0,0,0, NO_OBJ, 0, INT_MAX, 0, 0 }
/** An item with no restrictions: used for obsolete document types */
#define T(s,t,a,o)    { s, t, a, o, 0, INT_MAX, 0, 0 }
/** An item with no restrictions on multiplicity or location. */
#define T0N(s,t,a,o)  { s, t, a, o, 0, INT_MAX, 0, 0 }
/** An item that must appear exactly once */
#define T1(s,t,a,o)   { s, t, a, o, 1, 1, 0, 0 }
/** An item that must appear exactly once, at the start of the document */
#define T1_START(s,t,a,o)   { s, t, a, o, 1, 1, AT_START, 0 }
/** An item that must appear exactly once, at the end of the document */
#define T1_END(s,t,a,o)   { s, t, a, o, 1, 1, AT_END, 0 }
/** An item that must appear one or more times */
#define T1N(s,t,a,o)  { s, t, a, o, 1, INT_MAX, 0, 0 }
/** An item that must appear no more than once */
#define T01(s,t,a,o)  { s, t, a, o, 0, 1, 0, 0 }
/** An annotation that must appear no more than once */
#define A01(s,t,a,o)  { s, t, a, o, 0, 1, 0, 1 }

/** Argument multiplicity: any number of arguments. */
#define ARGS        0,INT_MAX,0
/** Argument multiplicity: no arguments. */
#define NO_ARGS     0,0,0
/** Argument multiplicity: concatenate all arguments. */
#define CONCAT_ARGS 1,1,1
/** Argument multiplicity: at least <b>n</b> arguments. */
#define GE(n)       n,INT_MAX,0
/** Argument multiplicity: exactly <b>n</b> arguments. */
#define EQ(n)       n,n,0
/**@}*/

/** Determines the parsing rules for a single token type. */
typedef struct token_rule_t {
  /** The string value of the keyword identifying the type of item. */
  const char *t;
  /** The corresponding directory_keyword enum. */
  directory_keyword v;
  /** Minimum number of arguments for this item */
  int min_args;
  /** Maximum number of arguments for this item */
  int max_args;
  /** If true, we concatenate all arguments for this item into a single
   * string. */
  int concat_args;
  /** Requirements on object syntax for this item. */
  obj_syntax os;
  /** Lowest number of times this item may appear in a document. */
  int min_cnt;
  /** Highest number of times this item may appear in a document. */
  int max_cnt;
  /** One or more of AT_START/AT_END to limit where the item may appear in a
   * document. */
  int pos;
  /** True iff this token is an annotation. */
  int is_annotation;
} token_rule_t;

void token_clear(directory_token_t *tok);

int tokenize_string(struct memarea_t *area,
                    const char *start, const char *end,
                    struct smartlist_t *out,
                    const token_rule_t *table,
                    int flags);
directory_token_t *get_next_token(struct memarea_t *area,
                                  const char **s,
                                  const char *eos,
                                  const token_rule_t *table);

directory_token_t *find_by_keyword_(struct smartlist_t *s,
                                    directory_keyword keyword,
                                    const char *keyword_str);

#define find_by_keyword(s, keyword) \
  find_by_keyword_((s), (keyword), #keyword)

directory_token_t *find_opt_by_keyword(const struct smartlist_t *s,
                                       directory_keyword keyword);
struct smartlist_t * find_all_by_keyword(const struct smartlist_t *s,
                                         directory_keyword k);

#endif /* !defined(TOR_PARSECOMMON_H) */
