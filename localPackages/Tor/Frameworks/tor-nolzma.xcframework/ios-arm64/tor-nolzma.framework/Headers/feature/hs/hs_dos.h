/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_dos.h
 * \brief Header file containing denial of service defenses for the HS
 *        subsystem for all versions.
 **/

#ifndef TOR_HS_DOS_H
#define TOR_HS_DOS_H

#include "core/or/or_circuit_st.h"

#include "feature/nodelist/networkstatus_st.h"

/* Init */
void hs_dos_init(void);

/* Consensus. */
void hs_dos_consensus_has_changed(const networkstatus_t *ns);

/* Introduction Point. */
bool hs_dos_can_send_intro2(or_circuit_t *s_intro_circ);
void hs_dos_setup_default_intro2_defenses(or_circuit_t *circ);

/* Statistics. */
uint64_t hs_dos_get_intro2_rejected_count(void);

#ifdef HS_DOS_PRIVATE

#ifdef TOR_UNIT_TESTS

STATIC uint32_t get_intro2_enable_consensus_param(const networkstatus_t *ns);
STATIC uint32_t get_intro2_rate_consensus_param(const networkstatus_t *ns);
STATIC uint32_t get_intro2_burst_consensus_param(const networkstatus_t *ns);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(HS_DOS_PRIVATE) */

#endif /* !defined(TOR_HS_DOS_H) */
