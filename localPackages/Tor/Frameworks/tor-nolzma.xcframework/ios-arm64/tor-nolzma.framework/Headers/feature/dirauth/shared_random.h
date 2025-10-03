/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_SHARED_RANDOM_H
#define TOR_SHARED_RANDOM_H

/**
 * \file shared_random.h
 *
 * \brief This file contains ABI/API of the shared random protocol defined in
 * proposal #250. Every public functions and data structure are namespaced
 * with "sr_" which stands for shared random.
 */

#include "core/or/or.h"

/** Protocol version */
#define SR_PROTO_VERSION  1
/** Default digest algorithm. */
#define SR_DIGEST_ALG DIGEST_SHA3_256
/** Invariant token in the SRV calculation. */
#define SR_SRV_TOKEN "shared-random"
/** Don't count the NUL terminated byte even though the TOKEN has it. */
#define SR_SRV_TOKEN_LEN (sizeof(SR_SRV_TOKEN) - 1)

/** Length of the random number (in bytes). */
#define SR_RANDOM_NUMBER_LEN 32
/** Size of a decoded commit value in a vote or state. It's a hash and a
 * timestamp. It adds up to 40 bytes. */
#define SR_COMMIT_LEN (sizeof(uint64_t) + DIGEST256_LEN)
/** Size of a decoded reveal value from a vote or state. It's a 64 bit
 * timestamp and the hashed random number. This adds up to 40 bytes. */
#define SR_REVEAL_LEN (sizeof(uint64_t) + DIGEST256_LEN)
/** Size of SRV message length. The construction is has follow:
 *  "shared-random" | INT_8(reveal_num) | INT_4(version) | PREV_SRV */
#define SR_SRV_MSG_LEN \
  (SR_SRV_TOKEN_LEN + sizeof(uint64_t) + sizeof(uint32_t) + DIGEST256_LEN)

/** Length of base64 encoded commit NOT including the NUL terminated byte.
 * Formula is taken from base64_encode_size. This adds up to 56 bytes. */
#define SR_COMMIT_BASE64_LEN (BASE64_LEN(SR_COMMIT_LEN))
/** Length of base64 encoded reveal NOT including the NUL terminated byte.
 * Formula is taken from base64_encode_size. This adds up to 56 bytes. */
#define SR_REVEAL_BASE64_LEN (BASE64_LEN(SR_REVEAL_LEN))
/** Length of base64 encoded shared random value. It's 32 bytes long so 44
 * bytes from the base64_encode_size formula. That includes the '='
 * character at the end. */
#define SR_SRV_VALUE_BASE64_LEN (BASE64_LEN(DIGEST256_LEN))

/** Assert if commit valid flag is not set. */
#define ASSERT_COMMIT_VALID(c) tor_assert((c)->valid)

/** Protocol phase. */
typedef enum {
  /** Commitment phase */
  SR_PHASE_COMMIT  = 1,
  /** Reveal phase */
  SR_PHASE_REVEAL  = 2,
} sr_phase_t;

/** A shared random value (SRV). */
typedef struct sr_srv_t {
  /** The number of reveal values used to derive this SRV. */
  uint64_t num_reveals;
  /** The actual value. This is the stored result of SHA3-256. */
  uint8_t value[DIGEST256_LEN];
} sr_srv_t;

/** A commit (either ours or from another authority). */
typedef struct sr_commit_t {
  /** Hashing algorithm used. */
  digest_algorithm_t alg;
  /** Indicate if this commit has been verified thus valid. */
  unsigned int valid:1;

  /* Commit owner info */

  /** The RSA identity key of the authority and its base16 representation,
   * which includes the NUL terminated byte. */
  char rsa_identity[DIGEST_LEN];
  char rsa_identity_hex[HEX_DIGEST_LEN + 1];

  /* Commitment information */

  /** Timestamp of reveal. Correspond to TIMESTAMP. */
  uint64_t reveal_ts;
  /* H(REVEAL) as found in COMMIT message. */
  char hashed_reveal[DIGEST256_LEN];
  /* Base64 encoded COMMIT. We use this to put it in our vote. */
  char encoded_commit[SR_COMMIT_BASE64_LEN + 1];

  /* Reveal information */

  /** H(RN) which is what we used as the random value for this commit. We
   * don't use the raw bytes since those are sent on the network thus
   * avoiding possible information leaks of our PRNG. */
  uint8_t random_number[SR_RANDOM_NUMBER_LEN];
  /** Timestamp of commit. Correspond to TIMESTAMP. */
  uint64_t commit_ts;
  /** This is the whole reveal message. We use it during verification */
  char encoded_reveal[SR_REVEAL_BASE64_LEN + 1];
} sr_commit_t;

/* API */

/* Public methods used _outside_ of the module.
 *
 * We need to nullify them if the module is disabled. */
#ifdef HAVE_MODULE_DIRAUTH

int sr_init(int save_to_disk);
void sr_save_and_cleanup(void);
void sr_act_post_consensus(const networkstatus_t *consensus);

#else /* !defined(HAVE_MODULE_DIRAUTH) */

static inline int
sr_init(int save_to_disk)
{
  (void) save_to_disk;
  /* Always return success. */
  return 0;
}

static inline void
sr_save_and_cleanup(void)
{
}

static inline void
sr_act_post_consensus(const networkstatus_t *consensus)
{
  (void) consensus;
}

#endif /* defined(HAVE_MODULE_DIRAUTH) */

/* Public methods used only by dirauth code. */

void sr_handle_received_commits(smartlist_t *commits,
                                crypto_pk_t *voter_key);
sr_commit_t *sr_parse_commit(const smartlist_t *args);
char *sr_get_string_for_vote(void);
char *sr_get_string_for_consensus(const smartlist_t *votes,
                                  int32_t num_srv_agreements);
void sr_commit_free_(sr_commit_t *commit);
#define sr_commit_free(sr) FREE_AND_NULL(sr_commit_t, sr_commit_free_, (sr))

/* Private methods (only used by shared_random_state.c): */
static inline
const char *sr_commit_get_rsa_fpr(const sr_commit_t *commit)
{
  return commit->rsa_identity_hex;
}

void sr_compute_srv(void);
sr_commit_t *sr_generate_our_commit(time_t timestamp,
                                    const authority_cert_t *my_rsa_cert);
sr_srv_t *sr_srv_dup(const sr_srv_t *orig);

#ifdef SHARED_RANDOM_PRIVATE

/* Encode */
STATIC int reveal_encode(const sr_commit_t *commit, char *dst, size_t len);
STATIC int commit_encode(const sr_commit_t *commit, char *dst, size_t len);
/* Decode. */
STATIC int commit_decode(const char *encoded, sr_commit_t *commit);
STATIC int reveal_decode(const char *encoded, sr_commit_t *commit);

STATIC int commit_has_reveal_value(const sr_commit_t *commit);

STATIC int verify_commit_and_reveal(const sr_commit_t *commit);

STATIC sr_srv_t *get_majority_srv_from_votes(const smartlist_t *votes,
                                             int current);

STATIC void save_commit_to_state(sr_commit_t *commit);
STATIC int commitments_are_the_same(const sr_commit_t *commit_one,
                                    const sr_commit_t *commit_two);
STATIC int commit_is_authoritative(const sr_commit_t *commit,
                                   const char *voter_key);
STATIC int should_keep_commit(const sr_commit_t *commit,
                              const char *voter_key,
                              sr_phase_t phase);
STATIC void save_commit_during_reveal_phase(const sr_commit_t *commit);

#endif /* defined(SHARED_RANDOM_PRIVATE) */

#ifdef TOR_UNIT_TESTS

void set_num_srv_agreements(int32_t value);

#endif /* TOR_UNIT_TESTS */

#endif /* !defined(TOR_SHARED_RANDOM_H) */
