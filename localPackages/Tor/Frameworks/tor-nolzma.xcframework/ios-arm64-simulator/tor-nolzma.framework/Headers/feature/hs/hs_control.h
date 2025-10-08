/* Copyright (c) 2017-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_control.h
 * \brief Header file containing control port event related code.
 **/

#ifndef TOR_HS_CONTROL_H
#define TOR_HS_CONTROL_H

#include "feature/hs/hs_ident.h"

/* Event "HS_DESC REQUESTED [...]" */
void hs_control_desc_event_requested(const ed25519_public_key_t *onion_pk,
                                     const char *base64_blinded_pk,
                                     const routerstatus_t *hsdir_rs);

/* Event "HS_DESC FAILED [...]" */
void hs_control_desc_event_failed(const hs_ident_dir_conn_t *ident,
                                  const char *hsdir_id_digest,
                                  const char *reason);

/* Event "HS_DESC RECEIVED [...]" */
void hs_control_desc_event_received(const hs_ident_dir_conn_t *ident,
                                    const char *hsdir_id_digest);

/* Event "HS_DESC CREATED [...]" */
void hs_control_desc_event_created(const char *onion_address,
                                   const ed25519_public_key_t *blinded_pk);

/* Event "HS_DESC UPLOAD [...]" */
void hs_control_desc_event_upload(const char *onion_address,
                                  const char *hsdir_id_digest,
                                  const ed25519_public_key_t *blinded_pk,
                                  const uint8_t *hsdir_index);

/* Event "HS_DESC UPLOADED [...]" */
void hs_control_desc_event_uploaded(const hs_ident_dir_conn_t *ident,
                                    const char *hsdir_id_digest);

/* Event "HS_DESC_CONTENT [...]" */
void hs_control_desc_event_content(const hs_ident_dir_conn_t *ident,
                                   const char *hsdir_id_digest,
                                   const char *body);

/* Command "HSPOST [...]" */
int hs_control_hspost_command(const char *body, const char *onion_address,
                              const smartlist_t *hsdirs_rs);

/* Command "HSFETCH [...]" */
void hs_control_hsfetch_command(const ed25519_public_key_t *onion_identity_pk,
                                const smartlist_t *hsdirs);

#endif /* !defined(TOR_HS_CONTROL_H) */

