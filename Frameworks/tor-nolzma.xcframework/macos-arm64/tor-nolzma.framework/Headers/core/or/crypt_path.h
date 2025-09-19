/**
 * \file crypt_path.h
 * \brief Header file for crypt_path.c.
 **/

#ifndef CRYPT_PATH_H
#define CRYPT_PATH_H

void cpath_assert_layer_ok(const crypt_path_t *cp);

void cpath_assert_ok(const crypt_path_t *cp);

int cpath_append_hop(crypt_path_t **head_ptr, extend_info_t *choice);

int cpath_init_circuit_crypto(crypt_path_t *cpath,
                              const char *key_data, size_t key_data_len,
                              int reverse, int is_hs_v3);

void
cpath_free(crypt_path_t *victim);

void cpath_extend_linked_list(crypt_path_t **head_ptr, crypt_path_t *new_hop);

void
cpath_crypt_cell(const crypt_path_t *cpath, uint8_t *payload, bool is_decrypt);

struct crypto_digest_t *
cpath_get_incoming_digest(const crypt_path_t *cpath);

void cpath_sendme_record_cell_digest(crypt_path_t *cpath,
                                     bool is_foward_digest);

void
cpath_set_cell_forward_digest(crypt_path_t *cpath, cell_t *cell);

crypt_path_t *cpath_get_next_non_open_hop(crypt_path_t *cpath);

void cpath_sendme_circuit_record_inbound_cell(crypt_path_t *cpath);

uint8_t *cpath_get_sendme_digest(crypt_path_t *cpath);

#if defined(TOR_UNIT_TESTS)
unsigned int cpath_get_n_hops(crypt_path_t **head_ptr);
#endif /* defined(TOR_UNIT_TESTS) */

#endif /* !defined(CRYPT_PATH_H) */
