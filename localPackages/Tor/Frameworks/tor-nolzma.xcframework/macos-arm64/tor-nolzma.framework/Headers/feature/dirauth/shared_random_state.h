/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file shared_random_state.h
 * @brief Header for shared_random_state.c
 **/

#ifndef TOR_SHARED_RANDOM_STATE_H
#define TOR_SHARED_RANDOM_STATE_H

#include "feature/dirauth/shared_random.h"

/** Action that can be performed on the state for any objects. */
typedef enum {
  SR_STATE_ACTION_GET     = 1,
  SR_STATE_ACTION_PUT     = 2,
  SR_STATE_ACTION_DEL     = 3,
  SR_STATE_ACTION_DEL_ALL = 4,
  SR_STATE_ACTION_SAVE    = 5,
} sr_state_action_t;

/** Object in the state that can be queried through the state API. */
typedef enum {
  /** Will return a single commit using an authority identity key. */
  SR_STATE_OBJ_COMMIT,
  /** Returns the entire list of commits from the state. */
  SR_STATE_OBJ_COMMITS,
  /** Return the current SRV object pointer. */
  SR_STATE_OBJ_CURSRV,
  /** Return the previous SRV object pointer. */
  SR_STATE_OBJ_PREVSRV,
  /** Return the phase. */
  SR_STATE_OBJ_PHASE,
  /** Get or Put the valid after time. */
  SR_STATE_OBJ_VALID_AFTER,
} sr_state_object_t;

/** State of the protocol. It's also saved on disk in fname. This data
 * structure MUST be synchronized at all time with the one on disk. */
typedef struct sr_state_t {
  /** Filename of the state file on disk. */
  char *fname;
  /** Version of the protocol. */
  uint32_t version;
  /** The valid-after of the voting period we have prepared the state for. */
  time_t valid_after;
  /** Until when is this state valid? */
  time_t valid_until;
  /** Protocol phase. */
  sr_phase_t phase;

  /** Number of runs completed. */
  uint64_t n_protocol_runs;
  /** The number of commitment rounds we've performed in this protocol run. */
  unsigned int n_commit_rounds;
  /** The number of reveal rounds we've performed in this protocol run. */
  unsigned int n_reveal_rounds;

  /** A map of all the received commitments for this protocol run. This is
   * indexed by authority RSA identity digest. */
  digestmap_t *commits;

  /** Current shared random value. */
  sr_srv_t *previous_srv;
  /** Previous shared random value. */
  sr_srv_t *current_srv;

  /** Indicate if the state contains an SRV that was _just_ generated. This is
   * used during voting so that we know whether to use the super majority rule
   * or not when deciding on keeping it for the consensus. It is _always_ set
   * to 0 post consensus.
   *
   * EDGE CASE: if an authority computes a new SRV then immediately reboots
   * and, once back up, votes for the current round, it won't know if the
   * SRV is fresh or not ultimately making it _NOT_ use the super majority
   * when deciding to put or not the SRV in the consensus. This is for now
   * an acceptable very rare edge case. */
  unsigned int is_srv_fresh:1;
} sr_state_t;

/** Persistent state of the protocol, as saved to disk. */
typedef struct sr_disk_state_t {
  uint32_t magic_;
  /** Version of the protocol. */
  int Version;
  /** Version of our running tor. */
  char *TorVersion;
  /** Creation time of this state */
  time_t ValidAfter;
  /** State valid until? */
  time_t ValidUntil;
  /** All commits seen that are valid. */
  struct config_line_t *Commit;
  /** Previous and current shared random value. */
  struct config_line_t *SharedRandValues;
  /** Extra Lines for configuration we might not know. */
  struct config_line_t *ExtraLines;
} sr_disk_state_t;

/* API */

/* Public methods: */

void sr_state_update(time_t valid_after);

/* Private methods (only used by shared-random.c): */

void sr_state_set_valid_after(time_t valid_after);
sr_phase_t sr_state_get_phase(void);
const sr_srv_t *sr_state_get_previous_srv(void);
const sr_srv_t *sr_state_get_current_srv(void);
void sr_state_set_previous_srv(const sr_srv_t *srv);
void sr_state_set_current_srv(const sr_srv_t *srv);
void sr_state_clean_srvs(void);
digestmap_t *sr_state_get_commits(void);
sr_commit_t *sr_state_get_commit(const char *rsa_fpr);
void sr_state_add_commit(sr_commit_t *commit);
void sr_state_delete_commits(void);
void sr_state_copy_reveal_info(sr_commit_t *saved_commit,
                               const sr_commit_t *commit);
unsigned int sr_state_srv_is_fresh(void);
void sr_state_set_fresh_srv(void);
void sr_state_unset_fresh_srv(void);
int sr_state_init(int save_to_disk, int read_from_disk);
int sr_state_is_initialized(void);
void sr_state_save(void);
void sr_state_free_all(void);

#ifdef SHARED_RANDOM_STATE_PRIVATE

STATIC int disk_state_load_from_disk_impl(const char *fname);

STATIC sr_phase_t get_sr_protocol_phase(time_t valid_after);

STATIC time_t get_state_valid_until_time(time_t now);
STATIC const char *get_phase_str(sr_phase_t phase);
STATIC void reset_state_for_new_protocol_run(time_t valid_after);
STATIC void new_protocol_run(time_t valid_after);
STATIC void state_rotate_srv(void);
STATIC int is_phase_transition(sr_phase_t next_phase);

#endif /* defined(SHARED_RANDOM_STATE_PRIVATE) */

#ifdef TOR_UNIT_TESTS

STATIC void set_sr_phase(sr_phase_t phase);
STATIC sr_state_t *get_sr_state(void);
STATIC void state_del_previous_srv(void);
STATIC void state_del_current_srv(void);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(TOR_SHARED_RANDOM_STATE_H) */
