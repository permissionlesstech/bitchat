/* Copyright (c) 2014-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#include "core/or/or.h"

#ifndef TOR_LOG_TEST_HELPERS_H
#define TOR_LOG_TEST_HELPERS_H

/** An element of mock_saved_logs(); records the log element that we
 * received. */
typedef struct mock_saved_log_entry_t {
  int severity;
  const char *funcname;
  const char *suffix;
  const char *format;
  char *generated_msg;
} mock_saved_log_entry_t;

void mock_clean_saved_logs(void);
const smartlist_t *mock_saved_logs(void);
void setup_capture_of_logs(int new_level);
void setup_full_capture_of_logs(int new_level);
void teardown_capture_of_logs(void);

int mock_saved_log_has_message(const char *msg);
int mock_saved_log_has_message_containing(const char *msg);
int mock_saved_log_has_message_not_containing(const char *msg);
int mock_saved_log_has_severity(int severity);
int mock_saved_log_has_entry(void);
int mock_saved_log_n_entries(void);
void mock_dump_saved_logs(void);

#define assert_log_predicate(predicate, failure_msg)   \
  do {                                                 \
    if (!(predicate)) {                                \
      TT_FAIL(failure_msg);                            \
      mock_dump_saved_logs();                          \
      TT_EXIT_TEST_FUNCTION;                           \
    }                                                  \
  } while (0)

#define expect_log_msg(str)                             \
  assert_log_predicate(mock_saved_log_has_message(str), \
                       ("expected log to contain \"%s\"", str));

#define expect_log_msg_containing(str) \
  assert_log_predicate(mock_saved_log_has_message_containing(str), \
                       ("expected log to contain \"%s\"", str));

#define expect_log_msg_not_containing(str) \
  assert_log_predicate(mock_saved_log_has_message_not_containing(str), \
                       ("expected log to not contain \"%s\"", str));

#define expect_log_msg_containing_either(str1, str2)                    \
  assert_log_predicate(mock_saved_log_has_message_containing(str1) ||   \
                       mock_saved_log_has_message_containing(str2),     \
           ("expected log to contain \"%s\" or \"%s\"", str1, str2));

#define expect_log_msg_containing_either3(str1, str2, str3)             \
  assert_log_predicate(mock_saved_log_has_message_containing(str1) ||   \
                       mock_saved_log_has_message_containing(str2) ||   \
                       mock_saved_log_has_message_containing(str3),     \
           ("expected log to contain \"%s\" or \"%s\" or \"%s\"",       \
                        str1, str2, str3))

#define expect_log_msg_containing_either4(str1, str2, str3, str4)       \
  assert_log_predicate(mock_saved_log_has_message_containing(str1) ||   \
                       mock_saved_log_has_message_containing(str2) ||   \
                       mock_saved_log_has_message_containing(str3) ||   \
                       mock_saved_log_has_message_containing(str4),     \
       ("expected log to contain \"%s\" or \"%s\" or \"%s\" or \"%s\"", \
                        str1, str2, str3, str4))

#define expect_single_log_msg(str) \
  do {                                                                  \
                                                                        \
    assert_log_predicate(mock_saved_log_has_message_containing(str) &&  \
                         mock_saved_log_n_entries() == 1,               \
                         ("expected log to contain exactly 1 message \"%s\"", \
                          str));                                        \
  } while (0)

#define expect_single_log_msg_containing(str) \
  do {                                                                  \
    assert_log_predicate(mock_saved_log_has_message_containing(str)&&   \
                         mock_saved_log_n_entries() == 1 ,              \
                    ("expected log to contain 1 message, containing \"%s\"",\
                     str));                                             \
  } while (0)

#define expect_no_log_msg(str) \
  assert_log_predicate(!mock_saved_log_has_message(str), \
                       ("expected log to not contain \"%s\"",str))

#define expect_no_log_msg_containing(str) \
  assert_log_predicate(!mock_saved_log_has_message_containing(str), \
                       ("expected log to not contain \"%s\"", str))

#define expect_log_severity(severity) \
  assert_log_predicate(mock_saved_log_has_severity(severity), \
                       ("expected log to contain severity " # severity))

#define expect_no_log_severity(severity) \
  assert_log_predicate(!mock_saved_log_has_severity(severity), \
                       ("expected log to not contain severity " # severity))

#define expect_log_entry() \
  assert_log_predicate(mock_saved_log_has_entry(), \
                       ("expected log to contain entries"))

#define expect_no_log_entry() \
  assert_log_predicate(!mock_saved_log_has_entry(), \
                       ("expected log to not contain entries"))

#endif /* !defined(TOR_LOG_TEST_HELPERS_H) */
