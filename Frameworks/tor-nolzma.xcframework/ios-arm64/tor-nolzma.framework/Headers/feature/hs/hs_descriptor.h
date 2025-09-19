/* Copyright (c) 2016-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file hs_descriptor.h
 * \brief Header file for hs_descriptor.c
 **/

#ifndef TOR_HS_DESCRIPTOR_H
#define TOR_HS_DESCRIPTOR_H

#include <stdint.h>

#include "core/or/or.h"
#include "trunnel/ed25519_cert.h" /* needed for trunnel */
#include "feature/nodelist/torcert.h"
#include "core/crypto/hs_ntor.h" /* for hs_subcredential_t */
#include "feature/hs/hs_pow.h"

/* Trunnel */
struct link_specifier_t;

/** The earliest descriptor format version we support. */
#define HS_DESC_SUPPORTED_FORMAT_VERSION_MIN 3
/** The latest descriptor format version we support. */
#define HS_DESC_SUPPORTED_FORMAT_VERSION_MAX 3

/** Default lifetime of a descriptor in seconds. The valus is set at 3 hours
 * which is 180 minutes or 10800 seconds. */
#define HS_DESC_DEFAULT_LIFETIME (3 * 60 * 60)
/** Maximum lifetime of a descriptor in seconds. The value is set at 12 hours
 * which is 720 minutes or 43200 seconds. */
#define HS_DESC_MAX_LIFETIME (12 * 60 * 60)
/** Lifetime of certificate in the descriptor. This defines the lifetime of the
 * descriptor signing key and the cross certification cert of that key. It is
 * set to 54 hours because a descriptor can be around for 48 hours and because
 * consensuses are used after the hour, add an extra 6 hours to give some time
 * for the service to stop using it. */
#define HS_DESC_CERT_LIFETIME (54 * 60 * 60)
/** Length of the salt needed for the encrypted section of a descriptor. */
#define HS_DESC_ENCRYPTED_SALT_LEN 16
/** Length of the KDF output value which is the length of the secret key,
 * the secret IV and MAC key length which is the length of H() output. */
#define HS_DESC_ENCRYPTED_KDF_OUTPUT_LEN \
  CIPHER256_KEY_LEN + CIPHER_IV_LEN + DIGEST256_LEN
/** Pad plaintext of superencrypted data section before encryption so that its
 * length is a multiple of this value. */
#define HS_DESC_SUPERENC_PLAINTEXT_PAD_MULTIPLE 10000
/** Maximum length in bytes of a full hidden service descriptor. */
#define HS_DESC_MAX_LEN 50000 /* 50kb max size */

/** Key length for the descriptor symmetric encryption. As specified in the
 * protocol, we use AES-256 for the encrypted section of the descriptor. The
 * following is the length in bytes and the bit size. */
#define HS_DESC_ENCRYPTED_KEY_LEN CIPHER256_KEY_LEN
#define HS_DESC_ENCRYPTED_BIT_SIZE (HS_DESC_ENCRYPTED_KEY_LEN * 8)

/** Length of each components in the auth client section in the descriptor. */
#define HS_DESC_CLIENT_ID_LEN 8
#define HS_DESC_DESCRIPTOR_COOKIE_LEN 16
#define HS_DESC_COOKIE_KEY_LEN 32
#define HS_DESC_COOKIE_KEY_BIT_SIZE (HS_DESC_COOKIE_KEY_LEN * 8)
#define HS_DESC_ENCRYPED_COOKIE_LEN HS_DESC_DESCRIPTOR_COOKIE_LEN

/** The number of auth client entries in the descriptor must be the multiple
 * of this constant. */
#define HS_DESC_AUTH_CLIENT_MULTIPLE 16

/** Type of authentication in the descriptor. */
typedef enum {
  HS_DESC_AUTH_ED25519 = 1
} hs_desc_auth_type_t;

/** Error code when decoding a descriptor. */
typedef enum {
  /* The configured client authorization for the requested .onion address
   * failed to decode the descriptor. */
  HS_DESC_DECODE_BAD_CLIENT_AUTH  = -6,

  /* The requested .onion address requires a client authorization. */
  HS_DESC_DECODE_NEED_CLIENT_AUTH = -5,

  /* Error during decryption of the encrypted layer. */
  HS_DESC_DECODE_ENCRYPTED_ERROR  = -4,

  /* Error during decryption of the super encrypted layer. */
  HS_DESC_DECODE_SUPERENC_ERROR   = -3,

  /* Error while decoding the plaintext section. */
  HS_DESC_DECODE_PLAINTEXT_ERROR  = -2,

  /* Generic error. */
  HS_DESC_DECODE_GENERIC_ERROR    = -1,

  /* Decoding a descriptor was successful. */
  HS_DESC_DECODE_OK               =  0,
} hs_desc_decode_status_t;

/** Introduction point information located in a descriptor. */
typedef struct hs_desc_intro_point_t {
  /** Link specifier(s) which details how to extend to the relay. This list
   * contains link_specifier_t objects. It MUST have at least one. */
  smartlist_t *link_specifiers;

  /** Onion key of the introduction point used to extend to it for the ntor
   * handshake. */
  curve25519_public_key_t onion_key;

  /** Authentication key used to establish the introduction point circuit and
   * cross-certifies the blinded public key for the replica thus signed by
   * the blinded key and in turn signs it. */
  tor_cert_t *auth_key_cert;

  /** Encryption key for the "ntor" type. */
  curve25519_public_key_t enc_key;

  /** Certificate cross certifying the descriptor signing key by the encryption
   * curve25519 key. This certificate contains the signing key and is of type
   * CERT_TYPE_CROSS_HS_IP_KEYS [0B]. */
  tor_cert_t *enc_key_cert;

  /** (Optional): If this introduction point is a legacy one that is version <=
   * 0.2.9.x (HSIntro=3), we use this extra key for the intro point to be able
   * to relay the cells to the service correctly. */
  struct {
    /** RSA public key. */
    crypto_pk_t *key;

    /** Cross certified cert with the descriptor signing key (RSA->Ed). Because
     * of the cross certification API, we need to keep the certificate binary
     * blob and its length in order to properly encode it after. */
    struct {
      uint8_t *encoded;
      size_t len;
    } cert;
  } legacy;

  /** True iff the introduction point has passed the cross certification. Upon
   * decoding an intro point, this must be true. */
  unsigned int cross_certified : 1;
} hs_desc_intro_point_t;

/** Authorized client information located in a descriptor. */
typedef struct hs_desc_authorized_client_t {
  /** An identifier that the client will use to identify which auth client
   * entry it needs to use. */
  uint8_t client_id[HS_DESC_CLIENT_ID_LEN];

  /** An IV that is used to decrypt the encrypted descriptor cookie. */
  uint8_t iv[CIPHER_IV_LEN];

  /** An encrypted descriptor cookie that the client needs to decrypt to use
   * it to decrypt the descriptor. */
  uint8_t encrypted_cookie[HS_DESC_ENCRYPED_COOKIE_LEN];
} hs_desc_authorized_client_t;

/** The encrypted data section of a descriptor. Obviously the data in this is
 * in plaintext but encrypted once encoded. */
typedef struct hs_desc_encrypted_data_t {
  /** Bitfield of CREATE2 cell supported formats. The only currently supported
   * format is ntor. */
  unsigned int create2_ntor : 1;

  /** A list of authentication types that a client must at least support one
   * in order to contact the service. Contains NULL terminated strings. */
  smartlist_t *intro_auth_types;

  /** Is this descriptor a single onion service? */
  unsigned int single_onion_service : 1;

  /** Flow control protocol version line. */
  char *flow_control_pv;
  uint8_t sendme_inc;

  /** PoW parameters. If NULL, it is not present. */
  hs_pow_desc_params_t *pow_params;

  /** A list of intro points. Contains hs_desc_intro_point_t objects. */
  smartlist_t *intro_points;

#ifdef TOR_UNIT_TESTS
  /** In unit tests only, we can include additional arbitrary plaintext.
   * This is used to test parser validation by adding invalid inner data to
   * descriptors that are otherwise correct and correctly encrypted. */
  const char *test_extra_plaintext;
#endif
} hs_desc_encrypted_data_t;

/** The superencrypted data section of a descriptor. Obviously the data in
 * this is in plaintext but encrypted once encoded. */
typedef struct hs_desc_superencrypted_data_t {
  /** This field contains ephemeral x25519 public key which is used by
   * the encryption scheme in the client authorization. */
  curve25519_public_key_t auth_ephemeral_pubkey;

  /** A list of authorized clients. Contains hs_desc_authorized_client_t
   * objects. */
  smartlist_t *clients;

  /** Decoding only: The b64-decoded encrypted blob from the descriptor */
  uint8_t *encrypted_blob;

  /** Decoding only: Size of the encrypted_blob */
  size_t encrypted_blob_size;
} hs_desc_superencrypted_data_t;

/** Plaintext data that is unencrypted information of the descriptor. */
typedef struct hs_desc_plaintext_data_t {
  /** Version of the descriptor format. Spec specifies this field as a
   * positive integer. */
  uint32_t version;

  /** The lifetime of the descriptor in seconds. */
  uint32_t lifetime_sec;

  /** Certificate with the short-term ed22519 descriptor signing key for the
   * replica which is signed by the blinded public key for that replica. */
  tor_cert_t *signing_key_cert;

  /** Signing public key which is used to sign the descriptor. Same public key
   * as in the signing key certificate. */
  ed25519_public_key_t signing_pubkey;

  /** Blinded public key used for this descriptor derived from the master
   * identity key and generated for a specific replica number. */
  ed25519_public_key_t blinded_pubkey;

  /** Revision counter is incremented at each upload, regardless of whether
   * the descriptor has changed. This avoids leaking whether the descriptor
   * has changed. Spec specifies this as a 8 bytes positive integer. */
  uint64_t revision_counter;

  /** Decoding only: The b64-decoded superencrypted blob from the descriptor */
  uint8_t *superencrypted_blob;

  /** Decoding only: Size of the superencrypted_blob */
  size_t superencrypted_blob_size;
} hs_desc_plaintext_data_t;

/** Service descriptor in its decoded form. */
typedef struct hs_descriptor_t {
  /** Contains the plaintext part of the descriptor. */
  hs_desc_plaintext_data_t plaintext_data;

  /** The following contains what's in the superencrypted part of the
   * descriptor. It's only encrypted in the encoded version of the descriptor
   * thus the data contained in that object is in plaintext. */
  hs_desc_superencrypted_data_t superencrypted_data;

  /** The following contains what's in the encrypted part of the descriptor.
   * It's only encrypted in the encoded version of the descriptor thus the
   * data contained in that object is in plaintext. */
  hs_desc_encrypted_data_t encrypted_data;

  /** Subcredentials of a service, used by the client and service to decrypt
   * the encrypted data. */
  hs_subcredential_t subcredential;
} hs_descriptor_t;

/** Return true iff the given descriptor format version is supported. */
static inline int
hs_desc_is_supported_version(uint32_t version)
{
  if (version < HS_DESC_SUPPORTED_FORMAT_VERSION_MIN ||
      version > HS_DESC_SUPPORTED_FORMAT_VERSION_MAX) {
    return 0;
  }
  return 1;
}

/* Public API. */

void hs_descriptor_free_(hs_descriptor_t *desc);
#define hs_descriptor_free(desc) \
  FREE_AND_NULL(hs_descriptor_t, hs_descriptor_free_, (desc))
void hs_desc_plaintext_data_free_(hs_desc_plaintext_data_t *desc);
#define hs_desc_plaintext_data_free(desc) \
  FREE_AND_NULL(hs_desc_plaintext_data_t, hs_desc_plaintext_data_free_, (desc))
void hs_desc_superencrypted_data_free_(hs_desc_superencrypted_data_t *desc);
#define hs_desc_superencrypted_data_free(desc) \
  FREE_AND_NULL(hs_desc_superencrypted_data_t, \
                hs_desc_superencrypted_data_free_, (desc))
void hs_desc_encrypted_data_free_(hs_desc_encrypted_data_t *desc);
#define hs_desc_encrypted_data_free(desc) \
  FREE_AND_NULL(hs_desc_encrypted_data_t, hs_desc_encrypted_data_free_, (desc))

void hs_descriptor_clear_intro_points(hs_descriptor_t *desc);

MOCK_DECL(int,
          hs_desc_encode_descriptor,(const hs_descriptor_t *desc,
                                     const ed25519_keypair_t *signing_kp,
                                     const uint8_t *descriptor_cookie,
                                     char **encoded_out));

hs_desc_decode_status_t hs_desc_decode_descriptor(const char *encoded,
                              const hs_subcredential_t *subcredential,
                              const curve25519_secret_key_t *client_auth_sk,
                              hs_descriptor_t **desc_out);
hs_desc_decode_status_t hs_desc_decode_plaintext(const char *encoded,
                             hs_desc_plaintext_data_t *plaintext);
hs_desc_decode_status_t hs_desc_decode_superencrypted(
                                const hs_descriptor_t *desc,
                                hs_desc_superencrypted_data_t *desc_out);
hs_desc_decode_status_t hs_desc_decode_encrypted(const hs_descriptor_t *desc,
                           const curve25519_secret_key_t *client_auth_sk,
                           hs_desc_encrypted_data_t *desc_out);

size_t hs_desc_obj_size(const hs_descriptor_t *data);
size_t hs_desc_plaintext_obj_size(const hs_desc_plaintext_data_t *data);

hs_desc_intro_point_t *hs_desc_intro_point_new(void);
void hs_desc_intro_point_free_(hs_desc_intro_point_t *ip);
#define hs_desc_intro_point_free(ip) \
  FREE_AND_NULL(hs_desc_intro_point_t, hs_desc_intro_point_free_, (ip))
void hs_desc_authorized_client_free_(hs_desc_authorized_client_t *client);
#define hs_desc_authorized_client_free(client) \
  FREE_AND_NULL(hs_desc_authorized_client_t, \
                hs_desc_authorized_client_free_, (client))

hs_desc_authorized_client_t *hs_desc_build_fake_authorized_client(void);

void hs_desc_build_authorized_client(const hs_subcredential_t *subcredential,
                                     const curve25519_public_key_t *
                                     client_auth_pk,
                                     const curve25519_secret_key_t *
                                     auth_ephemeral_sk,
                                     const uint8_t *descriptor_cookie,
                                     hs_desc_authorized_client_t *client_out);
void hs_desc_plaintext_data_free_contents(hs_desc_plaintext_data_t *desc);
void hs_desc_superencrypted_data_free_contents(
                                        hs_desc_superencrypted_data_t *desc);
void hs_desc_encrypted_data_free_contents(hs_desc_encrypted_data_t *desc);

bool hs_desc_supports_congestion_control(const hs_descriptor_t *desc);

#ifdef HS_DESCRIPTOR_PRIVATE

/* Encoding. */
STATIC char *encode_link_specifiers(const smartlist_t *specs);
STATIC size_t build_plaintext_padding(const char *plaintext,
                                      size_t plaintext_len,
                                      uint8_t **padded_out);
/* Decoding. */
STATIC smartlist_t *decode_link_specifiers(const char *encoded);
STATIC hs_desc_intro_point_t *decode_introduction_point(
                                const hs_descriptor_t *desc,
                                const char *text);
STATIC int encrypted_data_length_is_valid(size_t len);
STATIC int cert_is_valid(tor_cert_t *cert, uint8_t type,
                         const char *log_obj_type);
STATIC int desc_sig_is_valid(const char *b64_sig,
                             const ed25519_public_key_t *signing_pubkey,
                             const char *encoded_desc, size_t encoded_len);

MOCK_DECL(STATIC size_t, decrypt_desc_layer,(const hs_descriptor_t *desc,
                                             const uint8_t *descriptor_cookie,
                                             bool is_superencrypted_layer,
                                             char **decrypted_out));

STATIC hs_desc_decode_status_t desc_decode_encrypted_v3(
                         const hs_descriptor_t *desc,
                         const curve25519_secret_key_t *client_auth_sk,
                         hs_desc_encrypted_data_t *desc_encrypted_out);

STATIC hs_desc_decode_status_t
desc_decode_superencrypted_v3(const hs_descriptor_t *desc,
                              hs_desc_superencrypted_data_t *
                              desc_superencrypted_out);

MOCK_DECL(STATIC size_t, desc_decrypt_encrypted,(
                        const hs_descriptor_t *desc,
                        const curve25519_secret_key_t *client_auth_sk,
                        char **decrypted_out));

MOCK_DECL(STATIC size_t, desc_decrypt_superencrypted,(
                        const hs_descriptor_t *desc,
                        char **decrypted_out));

#endif /* defined(HS_DESCRIPTOR_PRIVATE) */

#endif /* !defined(TOR_HS_DESCRIPTOR_H) */
