/* Copyright (c) 2001, Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file log.h
 *
 * \brief Headers for log.c
 **/

#ifndef TOR_TORLOG_H
#define TOR_TORLOG_H

#include <stdarg.h>
#include "lib/cc/torint.h"
#include "lib/cc/compat_compiler.h"
#include "lib/defs/logging_types.h"
#include "lib/testsupport/testsupport.h"

#ifdef HAVE_SYSLOG_H
#include <syslog.h>
#define LOG_WARN LOG_WARNING
#if LOG_DEBUG < LOG_ERR
#ifndef COCCI
#error "Your syslog.h thinks high numbers are more important.  " \
       "We aren't prepared to deal with that."
#endif
#endif /* LOG_DEBUG < LOG_ERR */
#else /* !defined(HAVE_SYSLOG_H) */
/* Note: Syslog's logging code refers to priorities, with 0 being the most
 * important.  Thus, all our comparisons needed to be reversed when we added
 * syslog support.
 *
 * The upshot of this is that comments about log levels may be messed up: for
 * "maximum severity" read "most severe" and "numerically *lowest* severity".
 */

/** Debug-level severity: for hyper-verbose messages of no interest to
 * anybody but developers. */
#define LOG_DEBUG   7
/** Info-level severity: for messages that appear frequently during normal
 * operation. */
#define LOG_INFO    6
/** Notice-level severity: for messages that appear infrequently
 * during normal operation; that the user will probably care about;
 * and that are not errors.
 */
#define LOG_NOTICE  5
/** Warn-level severity: for messages that only appear when something has gone
 * wrong. */
#define LOG_WARN    4
/** Error-level severity: for messages that only appear when something has gone
 * very wrong, and the Tor process can no longer proceed. */
#define LOG_ERR     3
#endif /* defined(HAVE_SYSLOG_H) */

/* Logging domains */

/** Catch-all for miscellaneous events and fatal errors. */
#define LD_GENERAL  (UINT64_C(1)<<0)
/** The cryptography subsystem. */
#define LD_CRYPTO   (UINT64_C(1)<<1)
/** Networking. */
#define LD_NET      (UINT64_C(1)<<2)
/** Parsing and acting on our configuration. */
#define LD_CONFIG   (UINT64_C(1)<<3)
/** Reading and writing from the filesystem. */
#define LD_FS       (UINT64_C(1)<<4)
/** Other servers' (non)compliance with the Tor protocol. */
#define LD_PROTOCOL (UINT64_C(1)<<5)
/** Memory management. */
#define LD_MM       (UINT64_C(1)<<6)
/** HTTP implementation. */
#define LD_HTTP     (UINT64_C(1)<<7)
/** Application (socks) requests. */
#define LD_APP      (UINT64_C(1)<<8)
/** Communication via the controller protocol. */
#define LD_CONTROL  (UINT64_C(1)<<9)
/** Building, using, and managing circuits. */
#define LD_CIRC     (UINT64_C(1)<<10)
/** Hidden services. */
#define LD_REND     (UINT64_C(1)<<11)
/** Internal errors in this Tor process. */
#define LD_BUG      (UINT64_C(1)<<12)
/** Learning and using information about Tor servers. */
#define LD_DIR      (UINT64_C(1)<<13)
/** Learning and using information about Tor servers. */
#define LD_DIRSERV  (UINT64_C(1)<<14)
/** Onion routing protocol. */
#define LD_OR       (UINT64_C(1)<<15)
/** Generic edge-connection functionality. */
#define LD_EDGE     (UINT64_C(1)<<16)
#define LD_EXIT     LD_EDGE
/** Bandwidth accounting. */
#define LD_ACCT     (UINT64_C(1)<<17)
/** Router history */
#define LD_HIST     (UINT64_C(1)<<18)
/** OR handshaking */
#define LD_HANDSHAKE (UINT64_C(1)<<19)
/** Heartbeat messages */
#define LD_HEARTBEAT (UINT64_C(1)<<20)
/** Abstract channel_t code */
#define LD_CHANNEL   (UINT64_C(1)<<21)
/** Scheduler */
#define LD_SCHED     (UINT64_C(1)<<22)
/** Guard nodes */
#define LD_GUARD     (UINT64_C(1)<<23)
/** Generation and application of consensus diffs. */
#define LD_CONSDIFF  (UINT64_C(1)<<24)
/** Denial of Service mitigation. */
#define LD_DOS       (UINT64_C(1)<<25)
/** Processes */
#define LD_PROCESS   (UINT64_C(1)<<26)
/** Pluggable Transports. */
#define LD_PT        (UINT64_C(1)<<27)
/** Bootstrap tracker. */
#define LD_BTRACK    (UINT64_C(1)<<28)
/** Message-passing backend. */
#define LD_MESG      (UINT64_C(1)<<29)

/** The number of log domains. */
#define N_LOGGING_DOMAINS 30
/** The highest log domain */
#define HIGHEST_RESERVED_LD_DOMAIN_ (UINT64_C(1)<<(N_LOGGING_DOMAINS - 1))
/** All log domains. */
#define LD_ALL_DOMAINS ((~(UINT64_C(0)))>>(64 - N_LOGGING_DOMAINS))

/** The number of log flags. */
#define N_LOGGING_FLAGS 3
/** First bit that is reserved in log_domain_mask_t for non-domain flags. */
#define LOWEST_RESERVED_LD_FLAG_ (UINT64_C(1)<<(64 - N_LOGGING_FLAGS))
/** All log flags. */
#define LD_ALL_FLAGS ((~(UINT64_C(0)))<<(64 - N_LOGGING_FLAGS))

#ifdef TOR_UNIT_TESTS
/** This log message should not be intercepted by mock_saving_logv */
#define LD_NO_MOCK (UINT64_C(1)<<61)
#endif

/** This log message is not safe to send to a callback-based logger
 * immediately.  Used as a flag, not a log domain. */
#define LD_NOCB (UINT64_C(1)<<62)
/** This log message should not include a function name, even if it otherwise
 * would. Used as a flag, not a log domain. */
#define LD_NOFUNCNAME (UINT64_C(1)<<63)

/** Configures which severities are logged for each logging domain for a given
 * log target. */
typedef struct log_severity_list_t {
  /** For each log severity, a bitmask of which domains a given logger is
   * logging. */
  log_domain_mask_t masks[LOG_DEBUG-LOG_ERR+1];
} log_severity_list_t;

/** Callback type used for add_callback_log. */
typedef void (*log_callback)(int severity, log_domain_mask_t domain,
                             const char *msg);

void init_logging(int disable_startup_queue);
int parse_log_level(const char *level);
const char *log_level_to_string(int level);
int parse_log_severity_config(const char **cfg,
                              log_severity_list_t *severity_out);
void set_log_severity_config(int minSeverity, int maxSeverity,
                             log_severity_list_t *severity_out);
void add_stream_log(const log_severity_list_t *severity,
                    const char *name, int fd);
MOCK_DECL(int, add_file_log,(const log_severity_list_t *severity,
                             const char *filename,
                             int fd));

#ifdef HAVE_SYSLOG_H
int add_syslog_log(const log_severity_list_t *severity,
                   const char* syslog_identity_tag);
#endif // HAVE_SYSLOG_H.
int add_callback_log(const log_severity_list_t *severity, log_callback cb);
typedef void (*pending_callback_callback)(void);
void logs_set_pending_callback_callback(pending_callback_callback cb);
void logs_set_domain_logging(int enabled);
int get_min_log_level(void);
void switch_logs_debug(void);
void logs_free_all(void);
void logs_flush_sigsafe(void);
void add_default_log(int min_severity);
void close_temp_logs(void);
void rollback_log_changes(void);
void mark_logs_temp(void);
void change_callback_log_severity(int loglevelMin, int loglevelMax,
                                  log_callback cb);
void flush_pending_log_callbacks(void);
void flush_log_messages_from_startup(void);
void log_set_application_name(const char *name);
MOCK_DECL(void, set_log_time_granularity,(int granularity_msec));
void truncate_logs(void);

void tor_log(int severity, log_domain_mask_t domain, const char *format, ...)
  CHECK_PRINTF(3,4);

void tor_log_update_sigsafe_err_fds(void);

struct smartlist_t;
void tor_log_get_logfile_names(struct smartlist_t *out);

extern int log_global_min_severity_;

#ifdef TOR_COVERAGE
/* For coverage builds, we try to avoid our log_debug optimization, since it
 * can have weird effects on internal macro coverage. */
#define debug_logging_enabled() (1)
#else
static inline bool debug_logging_enabled(void);
/**
 * Return true iff debug logging is enabled for at least one domain.
 */
static inline bool debug_logging_enabled(void)
{
  return PREDICT_UNLIKELY(log_global_min_severity_ == LOG_DEBUG);
}
#endif /* defined(TOR_COVERAGE) */

void log_fn_(int severity, log_domain_mask_t domain,
             const char *funcname, const char *format, ...)
  CHECK_PRINTF(4,5);
struct ratelim_t;
void log_fn_ratelim_(struct ratelim_t *ratelim, int severity,
                     log_domain_mask_t domain, const char *funcname,
                     const char *format, ...)
  CHECK_PRINTF(5,6);

int log_message_is_interesting(int severity, log_domain_mask_t domain);
void tor_log_string(int severity, log_domain_mask_t domain,
                    const char *function, const char *string);

#if defined(__GNUC__) && __GNUC__ <= 3

/* These are the GCC varidaic macros, so that older versions of GCC don't
 * break. */

/** Log a message at level <b>severity</b>, using a pretty-printed version
 * of the current function name. */
#define log_fn(severity, domain, args...)               \
  log_fn_(severity, domain, __FUNCTION__, args)
/** As log_fn, but use <b>ratelim</b> (an instance of ratelim_t) to control
 * the frequency at which messages can appear.
 */
#define log_fn_ratelim(ratelim, severity, domain, args...)      \
  log_fn_ratelim_(ratelim, severity, domain, __FUNCTION__, args)
#define log_debug(domain, args...)                                      \
  STMT_BEGIN                                                            \
    if (debug_logging_enabled())                                        \
      log_fn_(LOG_DEBUG, domain, __FUNCTION__, args);                   \
  STMT_END
#define log_info(domain, args...)                           \
  log_fn_(LOG_INFO, domain, __FUNCTION__, args)
#define log_notice(domain, args...)                         \
  log_fn_(LOG_NOTICE, domain, __FUNCTION__, args)
#define log_warn(domain, args...)                           \
  log_fn_(LOG_WARN, domain, __FUNCTION__, args)
#define log_err(domain, args...)                            \
  log_fn_(LOG_ERR, domain, __FUNCTION__, args)

#else /* !(defined(__GNUC__) && __GNUC__ <= 3) */

/* Here are the c99 variadic macros, to work with non-GCC compilers */

#define log_debug(domain, args, ...)                                        \
  STMT_BEGIN                                                                \
    if (debug_logging_enabled())                                            \
      log_fn_(LOG_DEBUG, domain, __FUNCTION__, args, ##__VA_ARGS__);        \
  STMT_END
#define log_info(domain, args,...)                                      \
  log_fn_(LOG_INFO, domain, __FUNCTION__, args, ##__VA_ARGS__)
#define log_notice(domain, args,...)                                    \
  log_fn_(LOG_NOTICE, domain, __FUNCTION__, args, ##__VA_ARGS__)
#define log_warn(domain, args,...)                                      \
  log_fn_(LOG_WARN, domain, __FUNCTION__, args, ##__VA_ARGS__)
#define log_err(domain, args,...)                                       \
  log_fn_(LOG_ERR, domain, __FUNCTION__, args, ##__VA_ARGS__)
/** Log a message at level <b>severity</b>, using a pretty-printed version
 * of the current function name. */
#define log_fn(severity, domain, args,...)                              \
  log_fn_(severity, domain, __FUNCTION__, args, ##__VA_ARGS__)
/** As log_fn, but use <b>ratelim</b> (an instance of ratelim_t) to control
 * the frequency at which messages can appear.
 */
#define log_fn_ratelim(ratelim, severity, domain, args,...)      \
  log_fn_ratelim_(ratelim, severity, domain, __FUNCTION__, \
                  args, ##__VA_ARGS__)
#endif /* defined(__GNUC__) && __GNUC__ <= 3 */

/** This defines log levels that are linked in the Rust log module, rather
 * than re-defining these in both Rust and C.
 *
 * C_RUST_COUPLED src/rust/tor_log LogSeverity, LogDomain
 */
extern const int LOG_WARN_;
extern const int LOG_NOTICE_;
extern const log_domain_mask_t LD_NET_;
extern const log_domain_mask_t LD_GENERAL_;

#ifdef LOG_PRIVATE
MOCK_DECL(STATIC void, logv, (int severity, log_domain_mask_t domain,
    const char *funcname, const char *suffix, const char *format,
    va_list ap) CHECK_PRINTF(5,0));
MOCK_DECL(STATIC void, add_stream_log_impl,(
         const log_severity_list_t *severity, const char *name, int fd));
#endif /* defined(LOG_PRIVATE) */

#if defined(LOG_PRIVATE) || defined(TOR_UNIT_TESTS)
/** Given a severity, yields an index into log_severity_list_t.masks to use
 * for that severity. */
#define SEVERITY_MASK_IDX(sev) ((sev) - LOG_ERR)
#endif

#endif /* !defined(TOR_TORLOG_H) */
