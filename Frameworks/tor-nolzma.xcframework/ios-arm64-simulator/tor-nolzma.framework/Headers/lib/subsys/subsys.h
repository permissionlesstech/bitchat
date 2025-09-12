/* Copyright (c) 2003-2004, Roger Dingledine
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * @file subsys.h
 * @brief Types used to declare a subsystem.
 **/

#ifndef TOR_SUBSYS_T
#define TOR_SUBSYS_T

#include <stdbool.h>

struct pubsub_connector_t;
struct config_format_t;
struct smartlist_t;

/**
 * A subsystem is a part of Tor that is initialized, shut down, configured,
 * and connected to other parts of Tor.
 *
 * All callbacks are optional -- if a callback is set to NULL, the subsystem
 * manager will treat it as a no-op.
 *
 * You should use c99 named-field initializers with this structure, for
 * readability and safety. (There are a lot of functions here, all of them
 * optional, and many of them with similar signatures.)
 *
 * See @ref initialization for more information about initialization and
 * shutdown in Tor.
 *
 * To make a new subsystem, you declare a const instance of this type, and
 * include it on the list in subsystem_list.c.  The code that manages these
 * subsystems is in subsysmgr.c.
 **/
typedef struct subsys_fns_t {
  /**
   * The name of this subsystem.  It should be a programmer-readable
   * identifier.
   **/
  const char *name;

  /**
   * The file in which the subsystem object is declared. Used for debugging.
   **/
  const char *location;

  /**
   * Whether this subsystem is supported -- that is, whether it is compiled
   * into Tor.  For most subsystems, this should be true.
   **/
  bool supported;

  /**
   * The 'initialization level' for the subsystem.  It should run from -100
   * through +100.  The subsystems are initialized from lowest level to
   * highest, and shut down from highest level to lowest.
   **/
  int level;

  /**
   * Initialize any global components of this subsystem.
   *
   * This function MAY rely on any lower-level subsystem being initialized.
   *
   * This function MUST NOT rely on any runtime configuration information;
   * it is only for global state or pre-configuration state.
   *
   * (If you need to do any setup that depends on configuration, you'll need
   * to declare a configuration callback instead. (Not yet designed))
   *
   * This function MUST NOT have any parts that can fail.
   **/
  int (*initialize)(void);

  /**
   * Connect a subsystem to the message dispatch system.
   *
   * This function should use the macros in @refdir{lib/pubsub} to register a
   * set of messages that this subsystem may publish, and may subscribe to.
   *
   * See pubsub_macros.h for more information, and for examples.
   **/
  int (*add_pubsub)(struct pubsub_connector_t *);

  /**
   * Perform any necessary pre-fork cleanup.  This function may not fail.
   *
   * On Windows (and any other platforms without fork()), this function will
   * never be invoked.  Otherwise it is used when we are about to start
   * running as a background daemon, or when we are about to run a unit test
   * in a subprocess.  Unlike the subsys_fns_t.postfork callback, it is run
   * from the parent process.
   *
   * Note that we do not invoke this function when the child process's only
   * purpose is to call exec() and run another program.
   */
  void (*prefork)(void);

  /**
   * Perform any necessary post-fork setup. This function may not fail.
   *
   * On Windows (and any other platforms without fork()), this function will
   * never be invoked.  Otherwise it is used when we are about to start
   * running as a background daemon, or when we are about to run a unit test
   * in a subprocess.  Unlike the subsys_fns_t.prefork callback, it is run
   * from the child process.
   *
   * Note that we do not invoke this function when the child process's only
   * purpose is to call exec() and run another program.
   */
  void (*postfork)(void);

  /**
   * Free any thread-local resources held by this subsystem. Called before
   * the thread exits.
   *
   * This function is not allowed to fail.
   *
   * \bug Note that this callback is currently buggy: See \ticket{32103}.
   */
  void (*thread_cleanup)(void);

  /**
   * Free all resources held by this subsystem.
   *
   * This function is not allowed to fail.
   *
   * Subsystems are shut down when Tor is about to exit or return control to
   * an embedding program. This callback must return the process to a state
   * such that subsys_fns_t.init will succeed if invoked again.
   **/
  void (*shutdown)(void);

  /**
   * A config_format_t describing all of the torrc fields owned by this
   * subsystem.
   *
   * This object, if present, is registered in a confmgr_t for Tor's options,
   * and used to parse option fields from the command line and torrc file.
   **/
  const struct config_format_t *options_format;

  /**
   * A config_format_t describing all of the DataDir/state fields owned by
   * this subsystem.
   *
   * This object, if present, is registered in a confmgr_t for Tor's state,
   * and used to parse state fields from the DataDir/state file.
   **/
  const struct config_format_t *state_format;

  /**
   * Receive an options object as defined by options_format. Return 0
   * on success, -1 on failure.
   *
   * It is safe to store the pointer to the object until set_options()
   * is called again.
   *
   * This function is only called after all the validation code defined
   * by subsys_fns_t.options_format has passed.
   **/
  int (*set_options)(void *);

  /* XXXX Add an implementation for options_act_reversible() later in this
   * branch. */

  /**
   * Receive a state object as defined by state_format. Return 0 on success,
   * -1 on failure.
   *
   * It is safe to store the pointer to the object; set_state() is only
   * called on startup.
   *
   * This function is only called after all the validation code defined
   * by subsys_fns_t.state_format has passed.
   *
   * This function will only be called once per invocation of Tor, since
   * Tor does not reload its state while it is running.
   **/
  int (*set_state)(void *);

  /**
   * Update any information that needs to be stored in the provided state
   * object (as defined by state_format).  Return 0 on success, -1 on failure.
   *
   * The object provided here will be the same one as provided earlier to
   * set_state().  This method is called when we are about to save the state
   * to disk.
   **/
  int (*flush_state)(void *);

  /**
   * Return a list of metrics store of this subsystem. This is called
   * every time a request arrives on the MetricsPort.
   *
   * The list MUST contain metrics_store_t object and contains entries so it
   * can be formatted for the metrics port.
   *
   * This can return NULL or be NULL.
   **/
  const struct smartlist_t *(*get_metrics)(void);
} subsys_fns_t;

#ifndef COCCI
/**
 * Macro to declare a subsystem's location.
 **/
#define SUBSYS_DECLARE_LOCATION() \
  .location = __FILE__
#endif /* !defined(COCCI) */

/**
 * Lowest allowed subsystem level.
 **/
#define MIN_SUBSYS_LEVEL -100
/**
 * Highest allowed subsystem level.
 **/
#define MAX_SUBSYS_LEVEL 100

/**
 * All tor "libraries" (in src/libs) should have a subsystem level equal to or
 * less than this value.
 */
#define SUBSYS_LEVEL_LIBS -10

#endif /* !defined(TOR_SUBSYS_T) */
