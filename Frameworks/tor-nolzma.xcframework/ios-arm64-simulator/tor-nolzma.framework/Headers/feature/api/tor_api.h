/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file tor_api.h
 * \brief Public C API for the Tor network service.
 *
 * This interface is intended for use by programs that need to link Tor as
 * a library, and launch it in a separate thread.  If you have the ability
 * to run Tor as a separate executable, you should probably do that instead
 * of embedding it as a library.
 *
 * To use this API, first construct a tor_main_configuration_t object using
 * tor_main_configuration_new().  Then, you use one or more other function
 * calls (such as tor_main_configuration_set_command_line() to configure how
 * Tor should be run.  Finally, you pass the configuration object to
 * tor_run_main().
 *
 * At this point, tor_run_main() will block its thread to run a Tor daemon;
 * when the Tor daemon exits, it will return.  See notes on bugs and
 * limitations below.
 *
 * There is no other public C API to Tor: calling any C Tor function not
 * documented in this file is not guaranteed to be stable.
 **/

#ifndef TOR_API_H
#define TOR_API_H

typedef struct tor_main_configuration_t tor_main_configuration_t;

/**
 * Create and return a new tor_main_configuration().
 */
tor_main_configuration_t *tor_main_configuration_new(void);

/**
 * Set the command-line arguments in <b>cfg</b>.
 *
 * The <b>argc</b> and <b>argv</b> values here are as for main().  The
 * contents of the argv pointer must remain unchanged until tor_run_main() has
 * finished and you call tor_main_configuration_free().
 *
 * Return 0 on success, -1 on failure.
 */
int tor_main_configuration_set_command_line(tor_main_configuration_t *cfg,
                                            int argc, char *argv[]);

#ifdef _WIN32
typedef SOCKET tor_control_socket_t;
#define INVALID_TOR_CONTROL_SOCKET INVALID_SOCKET
#else
typedef int tor_control_socket_t;
#define INVALID_TOR_CONTROL_SOCKET (-1)
#endif /* defined(_WIN32) */

/** DOCDOC */
tor_control_socket_t tor_main_configuration_setup_control_socket(
                                          tor_main_configuration_t *cfg);

/**
 * Release all storage held in <b>cfg</b>.
 *
 * Once you have passed a tor_main_configuration_t to tor_run_main(), you
 * must not free it until tor_run_main() has finished.
 */
void tor_main_configuration_free(tor_main_configuration_t *cfg);

/**
 * Return the name and version of the software implementing the tor_api
 * functionality.  Current implementors are "tor" and "libtorrunner".
 *
 * Note that if you're using libtorrunner, you'll see the version of
 * libtorrunner, not the version of Tor that it's invoking for you.
 *
 * Added in Tor 0.3.5.1-alpha.
 *
 * Example return values include "tor 0.3.5.1-alpha" when linked directly
 * against tor, and "libtorrunner 0.3.5.1-alpha" when linked against
 * libtorrunner while it is invoking an arbitrary version of Tor.  HOWEVER,
 * the user MUST NOT depend on any particular format or contents of this
 * string: there may be other things that implement Tor in the future.
 **/
const char *tor_api_get_provider_version(void);

/**
 * Run the tor process, as if from the command line.
 *
 * The command line arguments from tor_main_configuration_set_command_line()
 * are taken as if they had been passed to main().
 *
 * This function will not return until Tor is done running.  It returns zero
 * on success, and nonzero on failure.
 *
 * If you want to control when Tor exits, make sure to configure a control
 * socket. The OwningControllerFD option may be helpful there.
 *
 * BUG 23847: Sometimes, if you call tor_main a second time (after it has
 * returned), Tor may crash or behave strangely.  We have fixed all issues of
 * this type that we could find, but more may remain.
 *
 * LIMITATION: You cannot run more than one instance of Tor in the same
 * process at the same time. Concurrent calls will cause undefined behavior.
 * We do not currently have plans to change this.
 *
 * LIMITATION: While we will try to fix any problems found here, you
 * should be aware that Tor was originally written to run as its own
 * process, and that the functionality of this file was added later.  If
 * you find any bugs or strange behavior, please report them, and we'll
 * try to straighten them out.
 */
int tor_run_main(const tor_main_configuration_t *);

/**
 * Run the tor process, as if from the command line.
 *
 * @deprecated Using this function from outside Tor is deprecated; you should
 * use tor_run_main() instead.
 *
 * BUGS: This function has all the same bugs as tor_run_main().
 *
 * LIMITATIONS: This function has all the limitations of tor_run_main().
 */
int tor_main(int argc, char **argv);

#endif /* !defined(TOR_API_H) */
