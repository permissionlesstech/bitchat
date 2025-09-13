/* Copyright (c) 2019-2020, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_pow.h
 * \brief Header file containing PoW denial of service defenses for the HS
 *        subsystem for all versions.
 **/

#ifndef TOR_HS_POW_H
#define TOR_HS_POW_H

#include "lib/evloop/compat_libevent.h"
#include "lib/evloop/token_bucket.h"
#include "lib/smartlist_core/smartlist_core.h"
#include "lib/crypt_ops/crypto_ed25519.h"

/* Service updates the suggested effort every HS_UPDATE_PERIOD seconds.
 * This parameter controls how often we can change hs descriptor data to
 * update suggested_effort, but it also controls the frequency of our
 * opportunities to increase or decrease effort. Lower values react to
 * attacks faster, higher values may be more stable.
 * Can this move to torrc? (Or the consensus?) The hs_cache timings are
 * related, and they're also hardcoded.
*/
#define HS_UPDATE_PERIOD 300

/** Length of random nonce (N) used in the PoW scheme. */
#define HS_POW_NONCE_LEN 16
/** Length of an E-quiX solution (S) in bytes. */
#define HS_POW_EQX_SOL_LEN 16
/** Length of blake2b hash result (R) used in the PoW scheme. */
#define HS_POW_HASH_LEN 4
/** Length of algorithm personalization string (P) used in the PoW scheme */
#define HS_POW_PSTRING_LEN 16
/** Algorithm personalization string (P) */
#define HS_POW_PSTRING "Tor hs intro v1\0"
/** Length of the blinded public ID for the onion service (ID) */
#define HS_POW_ID_LEN 32
/** Length of random seed used in the PoW scheme. */
#define HS_POW_SEED_LEN 32
/** Length of seed identification heading in the PoW scheme. */
#define HS_POW_SEED_HEAD_LEN 4
/** Length of an effort value */
#define HS_POW_EFFORT_LEN sizeof(uint32_t)
/** Offset of the nonce value within the challenge string */
#define HS_POW_NONCE_OFFSET \
  (HS_POW_PSTRING_LEN + HS_POW_ID_LEN + HS_POW_SEED_LEN)
/** Length of a PoW challenge. Construction as per prop327 is:
 *    (P || ID || C || N || INT_32(E))
 */
#define HS_POW_CHALLENGE_LEN \
  (HS_POW_PSTRING_LEN + HS_POW_ID_LEN + \
  HS_POW_SEED_LEN + HS_POW_NONCE_LEN + HS_POW_EFFORT_LEN)

/** Type of PoW in the descriptor. */
typedef enum {
  HS_POW_DESC_V1 = 1,
} hs_pow_desc_type_t;

/** Proof-of-Work parameters for DoS defense located in a descriptor. */
typedef struct hs_pow_desc_params_t {
  /** Type of PoW system being used. */
  hs_pow_desc_type_t type;

  /** Random 32-byte seed used as input the the PoW hash function */
  uint8_t seed[HS_POW_SEED_LEN];

  /** Specifies effort value that clients should aim for when contacting the
   * service. */
  uint32_t suggested_effort;

  /** Timestamp after which the above seed expires. */
  time_t expiration_time;
} hs_pow_desc_params_t;

/** The inputs to the PoW solver, derived from the descriptor data and the
  * client's per-connection effort choices. */
typedef struct hs_pow_solver_inputs_t {
  /** Seed value from a current descriptor */
  uint8_t seed[HS_POW_SEED_LEN];
  /** Blinded public ID for the onion service this puzzle is bound to */
  ed25519_public_key_t service_blinded_id;
  /** Effort chosen by the client. May be higher or lower than
   * suggested_effort in the descriptor. */
  uint32_t effort;
  /** Configuration option, choice of hash implementation. AUTOBOOL. */
  int CompiledProofOfWorkHash;
} hs_pow_solver_inputs_t;

/** State and parameters of PoW defenses, stored in the service state. */
typedef struct hs_pow_service_state_t {
  /* If PoW defenses are enabled this is a priority queue containing acceptable
   * requests that are awaiting rendezvous circuits to built, where priority is
   * based on the amount of effort that was exerted in the PoW. */
  smartlist_t *rend_request_pqueue;

  /* Low level mark for pqueue size. Below this length it's considered to be
   * effectively empty when calculating effort adjustments. */
  int pqueue_low_level;

  /* High level mark for pqueue size. When the queue is this length we will
   * trim it down to pqueue_high_level/2. */
  int pqueue_high_level;

  /* Event callback for dequeueing rend requests, paused when the queue is
   * empty or rate limited. */
  mainloop_event_t *pop_pqueue_ev;

  /* Token bucket for rate limiting the priority queue */
  token_bucket_ctr_t pqueue_bucket;

  /* The current seed being used in the PoW defenses. */
  uint8_t seed_current[HS_POW_SEED_LEN];

  /* The previous seed that was used in the PoW defenses. We accept solutions
   * for both the current and previous seed.  */
  uint8_t seed_previous[HS_POW_SEED_LEN];

  /* The time at which the current seed expires and rotates for a new one. */
  time_t expiration_time;

  /* The suggested effort that clients should use in order for their request to
   * be serviced in a timely manner. */
  uint32_t suggested_effort;

  /* The maximum effort of a request we've had to trim, this update period */
  uint32_t max_trimmed_effort;

  /* The following values are used when calculating and updating the suggested
   * effort every HS_UPDATE_PERIOD seconds. */

  /* Number of intro requests the service handled since last update. */
  uint32_t rend_handled;
  /* The next time at which to update the suggested effort. */
  time_t next_effort_update;
  /* Sum of effort of all valid requests received since the last update. */
  uint64_t total_effort;

  /* Did we have elements waiting in the queue during this period? */
  bool had_queue;
  /* Are we using pqueue_bucket to rate limit the pqueue? */
  bool using_pqueue_bucket;

} hs_pow_service_state_t;

/* Struct to store a solution to the PoW challenge. */
typedef struct hs_pow_solution_t {
  /* The nonce chosen to satisfy the PoW challenge's conditions. */
  uint8_t nonce[HS_POW_NONCE_LEN];

  /* The effort used in this solution. */
  uint32_t effort;

  /* A prefix of the seed used in this solution, so it can be identified. */
  uint8_t seed_head[HS_POW_SEED_HEAD_LEN];

  /* The Equi-X solution used in this PoW solution. */
  uint8_t equix_solution[HS_POW_EQX_SOL_LEN];
} hs_pow_solution_t;

#ifdef HAVE_MODULE_POW
#define have_module_pow() (1)

/* API */
int hs_pow_solve(const hs_pow_solver_inputs_t *pow_inputs,
                 hs_pow_solution_t *pow_solution_out);

int hs_pow_verify(const ed25519_public_key_t *service_blinded_id,
                  const hs_pow_service_state_t *pow_state,
                  const hs_pow_solution_t *pow_solution);

void hs_pow_remove_seed_from_cache(const uint8_t *seed_head);
void hs_pow_free_service_state(hs_pow_service_state_t *state);

int hs_pow_queue_work(uint32_t intro_circ_identifier,
                      const uint8_t *rend_circ_cookie,
                      const hs_pow_solver_inputs_t *pow_inputs);

#else /* !defined(HAVE_MODULE_POW) */
#define have_module_pow() (0)

static inline int
hs_pow_solve(const hs_pow_solver_inputs_t *pow_inputs,
             hs_pow_solution_t *pow_solution_out)
{
  (void)pow_inputs;
  (void)pow_solution_out;
  return -1;
}

static inline int
hs_pow_verify(const ed25519_public_key_t *service_blinded_id,
              const hs_pow_service_state_t *pow_state,
              const hs_pow_solution_t *pow_solution)
{
  (void)service_blinded_id;
  (void)pow_state;
  (void)pow_solution;
  return -1;
}

static inline void
hs_pow_remove_seed_from_cache(const uint8_t *seed_head)
{
  (void)seed_head;
}

static inline void
hs_pow_free_service_state(hs_pow_service_state_t *state)
{
  (void)state;
}

static inline int
hs_pow_queue_work(uint32_t intro_circ_identifier,
                  const uint8_t *rend_circ_cookie,
                  const hs_pow_solver_inputs_t *pow_inputs)
{
  (void)intro_circ_identifier;
  (void)rend_circ_cookie;
  (void)pow_inputs;
  return -1;
}

#endif /* defined(HAVE_MODULE_POW) */

#endif /* !defined(TOR_HS_POW_H) */
