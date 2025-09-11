/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_common.h
 * \brief Header file containing common data for the whole HS subsystem.
 **/

#ifndef TOR_HS_COMMON_H
#define TOR_HS_COMMON_H

#include "core/or/or.h"
#include "lib/defs/x25519_sizes.h"

struct curve25519_public_key_t;
struct ed25519_public_key_t;
struct ed25519_keypair_t;

/* Trunnel */
#include "trunnel/ed25519_cert.h"

/** Version 3 of the protocol (prop224). */
#define HS_VERSION_THREE 3
/** Earliest version we support. */
#define HS_VERSION_MIN HS_VERSION_THREE
/** Latest version we support. */
#define HS_VERSION_MAX HS_VERSION_THREE

/** Try to maintain this many intro points per service by default. */
#define NUM_INTRO_POINTS_DEFAULT 3
/** Maximum number of intro points per generic and version 2 service. */
#define NUM_INTRO_POINTS_MAX 10
/** Number of extra intro points we launch if our set of intro nodes is empty.
 * See proposal 155, section 4. */
#define NUM_INTRO_POINTS_EXTRA 2

/** If we can't build our intro circuits, don't retry for this long. */
#define INTRO_CIRC_RETRY_PERIOD (60*5)
/** Don't try to build more than this many circuits before giving up for a
 * while.*/
#define MAX_INTRO_CIRCS_PER_PERIOD 10
/** How many times will a hidden service operator attempt to connect to a
 * requested rendezvous point before giving up? */
#define MAX_REND_FAILURES 1
/** How many seconds should we spend trying to connect to a requested
 * rendezvous point before giving up? */
#define MAX_REND_TIMEOUT 30

/** String prefix for the signature of ESTABLISH_INTRO */
#define ESTABLISH_INTRO_SIG_PREFIX "Tor establish-intro cell v1"

/** The default HS time period length */
#define HS_TIME_PERIOD_LENGTH_DEFAULT 1440 /* 1440 minutes == one day */
/** The minimum time period length as seen in prop224 section [TIME-PERIODS] */
#define HS_TIME_PERIOD_LENGTH_MIN 30 /* minutes */
/** The minimum time period length as seen in prop224 section [TIME-PERIODS] */
#define HS_TIME_PERIOD_LENGTH_MAX (60 * 24 * 10) /* 10 days or 14400 minutes */

/** Prefix of the onion address checksum. */
#define HS_SERVICE_ADDR_CHECKSUM_PREFIX ".onion checksum"
/** Length of the checksum prefix minus the NUL terminated byte. */
#define HS_SERVICE_ADDR_CHECKSUM_PREFIX_LEN \
  (sizeof(HS_SERVICE_ADDR_CHECKSUM_PREFIX) - 1)
/** Length of the resulting checksum of the address. The construction of this
 * checksum looks like:
 *   CHECKSUM = ".onion checksum" || PUBKEY || VERSION
 * where VERSION is 1 byte. This is pre-hashing. */
#define HS_SERVICE_ADDR_CHECKSUM_INPUT_LEN \
  (HS_SERVICE_ADDR_CHECKSUM_PREFIX_LEN + ED25519_PUBKEY_LEN + sizeof(uint8_t))
/** The amount of bytes we use from the address checksum. */
#define HS_SERVICE_ADDR_CHECKSUM_LEN_USED 2
/** Length of the binary encoded service address which is of course before the
 * base32 encoding. Construction is:
 *    PUBKEY || CHECKSUM || VERSION
 * with 1 byte VERSION and 2 bytes CHECKSUM. The following is 35 bytes. */
#define HS_SERVICE_ADDR_LEN \
  (ED25519_PUBKEY_LEN + HS_SERVICE_ADDR_CHECKSUM_LEN_USED + sizeof(uint8_t))
/** Length of 'y' portion of 'y.onion' URL. This is base32 encoded and the
 * length ends up to 56 bytes (not counting the terminated NUL byte.) */
#define HS_SERVICE_ADDR_LEN_BASE32 \
  (CEIL_DIV(HS_SERVICE_ADDR_LEN * 8, 5))

/** The default HS time period length */
#define HS_TIME_PERIOD_LENGTH_DEFAULT 1440 /* 1440 minutes == one day */
/** The minimum time period length as seen in prop224 section [TIME-PERIODS] */
#define HS_TIME_PERIOD_LENGTH_MIN 30 /* minutes */
/** The minimum time period length as seen in prop224 section [TIME-PERIODS] */
#define HS_TIME_PERIOD_LENGTH_MAX (60 * 24 * 10) /* 10 days or 14400 minutes */
/** The time period rotation offset as seen in prop224 section
 * [TIME-PERIODS] */
#define HS_TIME_PERIOD_ROTATION_OFFSET (12 * 60) /* minutes */

/** Keyblinding parameter construction is as follow:
 *    "key-blind" || INT_8(period_num) || INT_8(start_period_sec) */
#define HS_KEYBLIND_NONCE_PREFIX "key-blind"
#define HS_KEYBLIND_NONCE_PREFIX_LEN (sizeof(HS_KEYBLIND_NONCE_PREFIX) - 1)
#define HS_KEYBLIND_NONCE_LEN \
  (HS_KEYBLIND_NONCE_PREFIX_LEN + sizeof(uint64_t) + sizeof(uint64_t))

/** Credential and subcredential prefix value. */
#define HS_CREDENTIAL_PREFIX "credential"
#define HS_CREDENTIAL_PREFIX_LEN (sizeof(HS_CREDENTIAL_PREFIX) - 1)
#define HS_SUBCREDENTIAL_PREFIX "subcredential"
#define HS_SUBCREDENTIAL_PREFIX_LEN (sizeof(HS_SUBCREDENTIAL_PREFIX) - 1)

/** Node hidden service stored at index prefix value. */
#define HS_INDEX_PREFIX "store-at-idx"
#define HS_INDEX_PREFIX_LEN (sizeof(HS_INDEX_PREFIX) - 1)

/** Node hidden service directory index prefix value. */
#define HSDIR_INDEX_PREFIX "node-idx"
#define HSDIR_INDEX_PREFIX_LEN (sizeof(HSDIR_INDEX_PREFIX) - 1)

/** Prefix of the shared random value disaster mode. */
#define HS_SRV_DISASTER_PREFIX "shared-random-disaster"
#define HS_SRV_DISASTER_PREFIX_LEN (sizeof(HS_SRV_DISASTER_PREFIX) - 1)

/** Default value of number of hsdir replicas (hsdir_n_replicas). */
#define HS_DEFAULT_HSDIR_N_REPLICAS 2
/** Default value of hsdir spread store (hsdir_spread_store). */
#define HS_DEFAULT_HSDIR_SPREAD_STORE 4
/** Default value of hsdir spread fetch (hsdir_spread_fetch). */
#define HS_DEFAULT_HSDIR_SPREAD_FETCH 3

/** The size of a legacy RENDEZVOUS1 cell which adds up to 168 bytes. It is
 * bigger than the 84 bytes needed for version 3 so we need to pad up to that
 * length so it is indistinguishable between versions. */
#define HS_LEGACY_RENDEZVOUS_CELL_SIZE \
  (REND_COOKIE_LEN + DH1024_KEY_LEN + DIGEST_LEN)

/** Type of authentication key used by an introduction point. */
typedef enum {
  HS_AUTH_KEY_TYPE_LEGACY  = 1,
  HS_AUTH_KEY_TYPE_ED25519 = 2,
} hs_auth_key_type_t;

/** Return value when adding an ephemeral service through the ADD_ONION
 * control port command. */
typedef enum {
  RSAE_BADAUTH     = -5, /**< Invalid auth_type/auth_clients */
  RSAE_BADVIRTPORT = -4, /**< Invalid VIRTPORT/TARGET(s) */
  RSAE_ADDREXISTS  = -3, /**< Onion address collision */
  RSAE_BADPRIVKEY  = -2, /**< Invalid public key */
  RSAE_INTERNAL    = -1, /**< Internal error */
  RSAE_OKAY        = 0   /**< Service added as expected */
} hs_service_add_ephemeral_status_t;

/** Represents the mapping from a virtual port of a rendezvous service to a
 * real port on some IP. */
typedef struct hs_port_config_t {
  /** The incoming HS virtual port we're mapping */
  uint16_t virtual_port;
  /** Is this an AF_UNIX port? */
  unsigned int is_unix_addr:1;
  /** The outgoing TCP port to use, if !is_unix_addr */
  uint16_t real_port;
  /** The outgoing IPv4 or IPv6 address to use, if !is_unix_addr */
  tor_addr_t real_addr;
  /** The socket path to connect to, if is_unix_addr */
  char unix_addr[FLEXIBLE_ARRAY_MEMBER];
} hs_port_config_t;

void hs_init(void);
void hs_free_all(void);

void hs_cleanup_circ(circuit_t *circ);

int hs_check_service_private_dir(const char *username, const char *path,
                                 unsigned int dir_group_readable,
                                 unsigned int create);
int hs_get_service_max_rend_failures(void);

char *hs_path_from_filename(const char *directory, const char *filename);
void hs_build_address(const struct ed25519_public_key_t *key, uint8_t version,
                      char *addr_out);
int hs_address_is_valid(const char *address);
int hs_parse_address(const char *address, struct ed25519_public_key_t *key_out,
                     uint8_t *checksum_out, uint8_t *version_out);
int hs_parse_address_no_log(const char *address,
                            struct ed25519_public_key_t *key_out,
                            uint8_t *checksum_out, uint8_t *version_out,
                            const char **errmsg);

void hs_build_blinded_pubkey(const struct ed25519_public_key_t *pubkey,
                             const uint8_t *secret, size_t secret_len,
                             uint64_t time_period_num,
                             struct ed25519_public_key_t *pubkey_out);
void hs_build_blinded_keypair(const struct ed25519_keypair_t *kp,
                              const uint8_t *secret, size_t secret_len,
                              uint64_t time_period_num,
                              struct ed25519_keypair_t *kp_out);
int hs_service_requires_uptime_circ(const smartlist_t *ports);

routerstatus_t *pick_hsdir(const char *desc_id, const char *desc_id_base32);

struct hs_subcredential_t;
void hs_get_subcredential(const struct ed25519_public_key_t *identity_pk,
                          const struct ed25519_public_key_t *blinded_pk,
                          struct hs_subcredential_t *subcred_out);

uint64_t hs_get_previous_time_period_num(time_t now);
uint64_t hs_get_time_period_num(time_t now);
uint64_t hs_get_next_time_period_num(time_t now);
time_t hs_get_start_time_of_next_time_period(time_t now);

MOCK_DECL(int, hs_in_period_between_tp_and_srv,
          (const networkstatus_t *consensus, time_t now));

uint8_t *hs_get_current_srv(uint64_t time_period_num,
                            const networkstatus_t *ns);
uint8_t *hs_get_previous_srv(uint64_t time_period_num,
                             const networkstatus_t *ns);

void hs_build_hsdir_index(const struct ed25519_public_key_t *identity_pk,
                          const uint8_t *srv, uint64_t period_num,
                          uint8_t *hsdir_index_out);
void hs_build_hs_index(uint64_t replica,
                       const struct ed25519_public_key_t *blinded_pk,
                       uint64_t period_num, uint8_t *hs_index_out);

int32_t hs_get_hsdir_n_replicas(void);
int32_t hs_get_hsdir_spread_fetch(void);
int32_t hs_get_hsdir_spread_store(void);

void hs_get_responsible_hsdirs(const struct ed25519_public_key_t *blinded_pk,
                              uint64_t time_period_num,
                              int use_second_hsdir_index,
                              int for_fetching, smartlist_t *responsible_dirs);
routerstatus_t *hs_pick_hsdir(smartlist_t *responsible_dirs,
                              const char *req_key_str,
                              bool *is_rate_limited_out);

time_t hs_hsdir_requery_period(const or_options_t *options);
time_t hs_lookup_last_hid_serv_request(routerstatus_t *hs_dir,
                                       const char *desc_id_base32,
                                       time_t now, int set);
void hs_clean_last_hid_serv_requests(time_t now);
void hs_purge_hid_serv_from_last_hid_serv_requests(const char *desc_id);
void hs_purge_last_hid_serv_requests(void);

int hs_set_conn_addr_port(const smartlist_t *ports, edge_connection_t *conn);
hs_port_config_t *hs_parse_port_config(const char *string, const char *sep,
                                       char **err_msg_out);
void hs_port_config_free_(hs_port_config_t *p);
#define hs_port_config_free(p) \
  FREE_AND_NULL(hs_port_config_t, hs_port_config_free_, (p))

void hs_inc_rdv_stream_counter(origin_circuit_t *circ);
void hs_dec_rdv_stream_counter(origin_circuit_t *circ);

extend_info_t *hs_get_extend_info_from_lspecs(const smartlist_t *lspecs,
                          const struct curve25519_public_key_t *onion_key,
                          int direct_conn);

link_specifier_t *link_specifier_dup(const link_specifier_t *src);

#ifdef HS_COMMON_PRIVATE

struct ed25519_public_key_t;

STATIC void get_disaster_srv(uint64_t time_period_num, uint8_t *srv_out);
STATIC void build_blinded_key_param(
                        const struct ed25519_public_key_t *pubkey,
                        const uint8_t *secret, size_t secret_len,
                        uint64_t period_num, uint64_t period_length,
                        uint8_t *param_out);

/** The period for which a hidden service directory cannot be queried for
 * the same descriptor ID again. */
#define REND_HID_SERV_DIR_REQUERY_PERIOD (15 * 60)
/** Test networks generate a new consensus every 5 or 10 seconds.
 * So allow them to requery HSDirs much faster. */
#define REND_HID_SERV_DIR_REQUERY_PERIOD_TESTING (5)

#ifdef TOR_UNIT_TESTS

STATIC strmap_t *get_last_hid_serv_requests(void);
STATIC uint64_t get_time_period_length(void);

STATIC uint8_t *get_first_cached_disaster_srv(void);
STATIC uint8_t *get_second_cached_disaster_srv(void);

#endif /* defined(TOR_UNIT_TESTS) */

#endif /* defined(HS_COMMON_PRIVATE) */

#endif /* !defined(TOR_HS_COMMON_H) */
