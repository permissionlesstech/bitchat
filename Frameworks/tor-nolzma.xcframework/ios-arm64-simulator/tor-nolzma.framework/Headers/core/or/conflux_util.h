/* Copyright (c) 2023, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file conflux_util.h
 * \brief Header file for conflux_util.c.
 **/

#ifndef TOR_CONFLUX_UTIL_H
#define TOR_CONFLUX_UTIL_H

/* Forward decls */
typedef struct edge_connection_t edge_connection_t;
typedef struct crypt_path_t crypt_path_t;
typedef struct origin_circuit_t origin_circuit_t;
typedef struct conflux_t conflux_t;

/* True iff the given circuit_t circ is conflux related. */
static inline bool
CIRCUIT_IS_CONFLUX(const circuit_t *circ)
{
  if (circ->conflux_pending_nonce) {
    if (CIRCUIT_IS_ORIGIN(circ))
      tor_assert_nonfatal(circ->purpose == CIRCUIT_PURPOSE_CONFLUX_UNLINKED);
    return true;
  } else if (circ->conflux) {
    if (CIRCUIT_IS_ORIGIN(circ))
      tor_assert_nonfatal(circ->purpose == CIRCUIT_PURPOSE_CONFLUX_LINKED);
    return true;
  } else {
    /* We don't assert on purposes here because we can end up in this branch
     * with circ->conflux being NULL but for a conflux purpose. This happens in
     * the about_to_free() code path. */
    return false;
  }
}

const uint8_t *conflux_get_nonce(const circuit_t *circ);
uint64_t conflux_get_circ_rtt(const circuit_t *circ);

int circuit_get_package_window(circuit_t *circ,
                               const crypt_path_t *cpath);
bool conflux_can_send(conflux_t *cfx);

bool edge_uses_cpath(const edge_connection_t *conn,
                     const crypt_path_t *cpath);
crypt_path_t *conflux_get_destination_hop(circuit_t *circ);
bool conflux_validate_source_hop(circuit_t *in_circ,
                            crypt_path_t *layer_hint);
uint64_t edge_get_max_rtt(const edge_connection_t *stream);
bool relay_crypt_from_last_hop(const origin_circuit_t *circ,
                          const crypt_path_t *layer_hint);

void conflux_update_p_streams(origin_circuit_t *, edge_connection_t *);
void conflux_update_half_streams(origin_circuit_t *, smartlist_t *);
void conflux_update_n_streams(or_circuit_t *, edge_connection_t *);
void conflux_update_resolving_streams(or_circuit_t *, edge_connection_t *);
void conflux_sync_circ_fields(conflux_t *cfx, origin_circuit_t *ref_circ);
void conflux_validate_stream_lists(const conflux_t *cfx);
void conflux_validate_legs(const conflux_t *cfx);

#endif /* TOR_CONFLUX_UTIL_H */

