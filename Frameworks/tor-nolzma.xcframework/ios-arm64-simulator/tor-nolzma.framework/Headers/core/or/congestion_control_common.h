/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file congestion_control_common.h
 * \brief Public APIs for congestion control
 **/

#ifndef TOR_CONGESTION_CONTROL_COMMON_H
#define TOR_CONGESTION_CONTROL_COMMON_H

#include "core/crypto/onion_crypto.h"
#include "core/or/crypt_path_st.h"
#include "core/or/circuit_st.h"

/* The maximum whole number of cells that can fit in a
 * full TLS record. This is 31. */
#define TLS_RECORD_MAX_CELLS ((16 * 1024) / CELL_MAX_NETWORK_SIZE)

typedef struct congestion_control_t congestion_control_t;

/**
 * Specifies the path type to help choose congestion control
 * parameters. Since these paths are different lengths, they
 * will need different queue parameters. */
typedef enum {
  CC_PATH_EXIT = 0,
  CC_PATH_ONION = 1,
  CC_PATH_ONION_SOS = 2,
  CC_PATH_ONION_VG = 3,
  CC_PATH_SBWS = 4,
} cc_path_t;

/** The length of a path for sbws measurement */
#define SBWS_ROUTE_LEN 2

/** Wrapper for the free function, set the CC pointer to NULL after free */
#define congestion_control_free(cc) \
    FREE_AND_NULL(congestion_control_t, congestion_control_free_, cc)

void congestion_control_free_(congestion_control_t *cc);

struct circuit_params_t;
congestion_control_t *congestion_control_new(
                                    const struct circuit_params_t *params,
                                    cc_path_t path);

int congestion_control_dispatch_cc_alg(congestion_control_t *cc,
                                       circuit_t *circ);

void congestion_control_note_cell_sent(congestion_control_t *cc,
                                       const circuit_t *circ,
                                       const crypt_path_t *cpath);

bool congestion_control_update_circuit_estimates(congestion_control_t *,
                                                 const circuit_t *);

int congestion_control_get_package_window(const circuit_t *,
                                          const crypt_path_t *);

int sendme_get_inc_count(const circuit_t *, const crypt_path_t *);
bool circuit_sent_cell_for_sendme(const circuit_t *, const crypt_path_t *);
bool is_monotime_clock_reliable(void);

void congestion_control_new_consensus_params(const networkstatus_t *ns);

bool congestion_control_enabled(void);

int congestion_control_build_ext_request(uint8_t **msg_out,
                                         size_t *msg_len_out);
int congestion_control_parse_ext_request(const uint8_t *msg,
                                         const size_t msg_len);
int congestion_control_build_ext_response(const circuit_params_t *our_params,
                                          const circuit_params_t *circ_params,
                                          uint8_t **msg_out,
                                          size_t *msg_len_out);
int congestion_control_parse_ext_response(const uint8_t *msg,
                                          const size_t msg_len,
                                          circuit_params_t *params_out);
bool congestion_control_validate_sendme_increment(uint8_t sendme_inc);
char *congestion_control_get_control_port_fields(const origin_circuit_t *);

uint64_t congestion_control_get_num_rtt_reset(void);
uint64_t congestion_control_get_num_clock_stalls(void);

extern uint64_t cc_stats_circs_created;

/* Ugh, C.. these are private. Use the getter instead, when
 * external to the congestion control code. */
extern uint32_t or_conn_highwater;
extern uint32_t or_conn_lowwater;
extern int32_t cell_queue_high;
extern int32_t cell_queue_low;
extern uint8_t cc_sendme_inc;

/** Stop writing on an orconn when its outbuf is this large */
static inline uint32_t
or_conn_highwatermark(void)
{
  return or_conn_highwater;
}

/** Resume writing on an orconn when its outbuf is less than this */
static inline uint32_t
or_conn_lowwatermark(void)
{
  return or_conn_lowwater;
}

/** Stop reading on edge connections when we have this many cells
 * waiting on the appropriate queue. */
static inline int32_t
cell_queue_highwatermark(void)
{
  return cell_queue_high;
}

/** Start reading from edge connections again when we get down to this many
 * cells. */
static inline int32_t
cell_queue_lowwatermark(void)
{
  return cell_queue_low;
}

/** Returns the sendme inc rate cached from the most recent consensus */
static inline uint8_t
congestion_control_sendme_inc(void)
{
  return cc_sendme_inc;
}

/**
 * Compute an N-count EWMA, aka N-EWMA. N-EWMA is defined as:
 *  EWMA = alpha*value + (1-alpha)*EWMA_prev
 * with alpha = 2/(N+1).
 *
 * This works out to:
 *  EWMA = value*2/(N+1) + EMA_prev*(N-1)/(N+1)
 *       = (value*2 + EWMA_prev*(N-1))/(N+1)
 */
static inline uint64_t
n_count_ewma(uint64_t curr, uint64_t prev, uint64_t N)
{
  if (prev == 0)
    return curr;
  else
    return (2*curr + (N-1)*prev)/(N+1);
}

/**
 * Helper function that gives us a percentile weighted-average between
 * two values. The pct_max argument specifies the percentage weight of the
 * maximum of a and b, when computing this weighted-average.
 *
 * This also allows this function to be used as either MIN() or a MAX()
 * by this parameterization. It is MIN() when pct_max==0;
 * it is MAX() when pct_max==100; it is avg() when pct_max==50; it is a
 * weighted-average for values in between.
 */
static inline uint64_t
percent_max_mix(uint64_t a, uint64_t b, uint8_t pct_max)
{
  uint64_t max = MAX(a, b);
  uint64_t min = MIN(a, b);

  if (BUG(pct_max > 100)) {
    return max;
  }

  return pct_max*max/100 + (100-pct_max)*min/100;
}

/* Private section starts. */
#ifdef TOR_CONGESTION_CONTROL_COMMON_PRIVATE
STATIC uint64_t congestion_control_update_circuit_rtt(congestion_control_t *,
                                                      uint64_t);

STATIC bool time_delta_stalled_or_jumped(const congestion_control_t *cc,
                                  uint64_t old_delta, uint64_t new_delta);

STATIC void enqueue_timestamp(smartlist_t *timestamps_u64,
                                     uint64_t timestamp_usec);

/*
 * Unit tests declaractions.
 */
#ifdef TOR_UNIT_TESTS

extern bool is_monotime_clock_broken;
extern cc_alg_t cc_alg;
void congestion_control_set_cc_enabled(void);
void congestion_control_set_cc_disabled(void);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(TOR_CONGESTION_CONTROL_PRIVATE) */

#endif /* !defined(TOR_CONGESTION_CONTROL_COMMON_H) */
