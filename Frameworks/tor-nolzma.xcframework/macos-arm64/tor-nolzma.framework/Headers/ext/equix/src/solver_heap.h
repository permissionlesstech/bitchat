/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef SOLVER_HEAP_H
#define SOLVER_HEAP_H

#include <stdint.h>
#include <equix.h>

#define INDEX_SPACE (UINT32_C(1) << 16)
#define NUM_COARSE_BUCKETS 256
#define NUM_FINE_BUCKETS 128
#define COARSE_BUCKET_ITEMS 336
#define FINE_BUCKET_ITEMS 12

typedef uint16_t fine_item;

typedef struct fine_bucket {
	fine_item items[FINE_BUCKET_ITEMS];
} fine_bucket;

typedef struct fine_hashtab {
	uint8_t counts[NUM_FINE_BUCKETS];
	fine_bucket buckets[NUM_FINE_BUCKETS];
} fine_hashtab;

typedef equix_idx stage1_idx_item; /* 16 bits */

typedef uint64_t stage1_data_item; /* 52 bits */

typedef struct stage1_idx_bucket {
	stage1_idx_item items[COARSE_BUCKET_ITEMS];
} stage1_idx_bucket;

typedef struct stage1_data_bucket {
	stage1_data_item items[COARSE_BUCKET_ITEMS];
} stage1_data_bucket;

typedef struct stage1_idx_hashtab {
	uint16_t counts[NUM_COARSE_BUCKETS];
	stage1_idx_bucket buckets[NUM_COARSE_BUCKETS];
} stage1_idx_hashtab;

typedef struct stage1_data_hashtab {
	stage1_data_bucket buckets[NUM_COARSE_BUCKETS];
} stage1_data_hashtab;

typedef uint32_t stage2_idx_item; /* 26 bits: 8 bits = left bucket index
                                              9 bits = left item index
                                              9 bits = right item index */

typedef struct stage2_idx_bucket {
	stage2_idx_item items[COARSE_BUCKET_ITEMS];
} stage2_idx_bucket;

typedef struct stage2_idx_hashtab {
	uint16_t counts[NUM_COARSE_BUCKETS];
	stage2_idx_bucket buckets[NUM_COARSE_BUCKETS];
} stage2_idx_hashtab;

#ifdef SOLVER_PACKED_STAGE2
#pragma pack(push, 1)
typedef struct stage2_data_item {
	uint32_t upper; /* 22 bits */
	uint8_t middle; /* 8 bits */
	uint8_t lower;  /* 7 bits */
} stage2_data_item;
#pragma pack(pop)
#else
typedef uint64_t stage2_data_item; /* 37 bits */
#endif

typedef struct stage2_data_bucket {
	stage2_data_item items[COARSE_BUCKET_ITEMS];
} stage2_data_bucket;

typedef struct stage2_data_hashtab {
	stage2_data_bucket buckets[NUM_COARSE_BUCKETS];
} stage2_data_hashtab;

typedef uint32_t stage3_data_item; /* 22 bits */

typedef struct stage3_data_bucket {
	stage3_data_item items[COARSE_BUCKET_ITEMS];
} stage3_data_bucket;

typedef struct stage3_data_hashtab {
	stage3_data_bucket buckets[NUM_COARSE_BUCKETS];
} stage3_data_hashtab;

typedef stage2_idx_hashtab stage3_idx_hashtab;
typedef stage2_idx_item stage3_idx_item;

typedef struct solver_heap {
    stage1_idx_hashtab stage1_indices;           /* 172 544 bytes */
    stage2_idx_hashtab stage2_indices;           /* 344 576 bytes */
    stage2_data_hashtab stage2_data;             /* 688 128 bytes */
    union {
        stage1_data_hashtab stage1_data;         /* 688 128 bytes */
        struct {
            stage3_idx_hashtab stage3_indices;   /* 344 576 bytes */
            stage3_data_hashtab stage3_data;     /* 344 064 bytes */
        };
    };
    fine_hashtab scratch_ht;                     /*   3 200 bytes */
} solver_heap;                          /* TOTAL: 1 897 088 bytes */

#endif
