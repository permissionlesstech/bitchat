/* Copyright (c) 2013-2024, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file workqueue.h
 * \brief Header for workqueue.c
 **/

#ifndef TOR_WORKQUEUE_H
#define TOR_WORKQUEUE_H

#include "lib/cc/torint.h"

/** A replyqueue is used to tell the main thread about the outcome of
 * work that we queued for the workers. */
typedef struct replyqueue_t replyqueue_t;
/** A thread-pool manages starting threads and passing work to them. */
typedef struct threadpool_t threadpool_t;
/** A workqueue entry represents a request that has been passed to a thread
 * pool. */
typedef struct workqueue_entry_t workqueue_entry_t;

/** Possible return value from a work function: */
typedef enum workqueue_reply_t {
  WQ_RPL_REPLY = 0, /** indicates success */
  WQ_RPL_ERROR = 1, /** indicates fatal error */
  WQ_RPL_SHUTDOWN = 2, /** indicates thread is shutting down */
} workqueue_reply_t;

/** Possible priorities for work.  Lower numeric values are more important. */
typedef enum workqueue_priority_t {
  WQ_PRI_HIGH = 0,
  WQ_PRI_MED  = 1,
  WQ_PRI_LOW  = 2,
} workqueue_priority_t;

workqueue_entry_t *threadpool_queue_work_priority(threadpool_t *pool,
                                    workqueue_priority_t prio,
                                    workqueue_reply_t (*fn)(void *,
                                                            void *),
                                    void (*reply_fn)(void *),
                                    void *arg);

workqueue_entry_t *threadpool_queue_work(threadpool_t *pool,
                                         workqueue_reply_t (*fn)(void *,
                                                                 void *),
                                         void (*reply_fn)(void *),
                                         void *arg);

int threadpool_queue_update(threadpool_t *pool,
                            void *(*dup_fn)(void *),
                            workqueue_reply_t (*fn)(void *, void *),
                            void (*free_fn)(void *),
                            void *arg);
void *workqueue_entry_cancel(workqueue_entry_t *pending_work);
threadpool_t *threadpool_new(int n_threads,
                             replyqueue_t *replyqueue,
                             void *(*new_thread_state_fn)(void*),
                             void (*free_thread_state_fn)(void*),
                             void *arg);
void threadpool_free_(threadpool_t *tp);
#define threadpool_free(pool) \
  FREE_AND_NULL(threadpool_t, threadpool_free_, (pool))
replyqueue_t *threadpool_get_replyqueue(threadpool_t *tp);

replyqueue_t *replyqueue_new(uint32_t alertsocks_flags);
void replyqueue_process(replyqueue_t *queue);

int threadpool_register_reply_event(threadpool_t *tp,
                                    void (*cb)(threadpool_t *tp));
unsigned int threadpool_get_n_threads(threadpool_t *tp);

#endif /* !defined(TOR_WORKQUEUE_H) */
