#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// Forward declarations from Tor's public embedding API (tor_api.h)
typedef struct tor_main_configuration_t tor_main_configuration_t;
tor_main_configuration_t *tor_main_configuration_new(void);
int tor_main_configuration_set_command_line(tor_main_configuration_t *cfg,
                                            int argc,
                                            char **argv);
void tor_main_configuration_free(tor_main_configuration_t *cfg);
int tor_run_main(const tor_main_configuration_t *);

static pthread_t tor_thread;
static int tor_thread_started = 0;
static int owning_fd_app = -1;   // App side; close to trigger shutdown
static int owning_fd_tor = -1;   // Tor side; closed when tor exits

// Persisted copies of args for restart convenience
static char data_dir_copy[PATH_MAX] = {0};
static char socks_arg_copy[64] = {0};
static char control_arg_copy[64] = {0};
static char fd_arg_copy[16] = {0};

// Keep argv array alive as required by tor_api.h until tor_run_main finishes
static char **argv_owned = NULL;
static int argv_owned_argc = 0;

// Public: return nonzero if tor thread appears to be running
int tor_host_is_running(void) {
  return (tor_thread_started != 0) && (owning_fd_tor != -1);
}

static void *tor_thread_main(void *arg) {
  tor_main_configuration_t *cfg = (tor_main_configuration_t *)arg;
  int rc = tor_run_main(cfg);            // blocks until tor exits
  tor_main_configuration_free(cfg);
  if (argv_owned) { free(argv_owned); argv_owned = NULL; argv_owned_argc = 0; }
  // Do not close owning_fd_tor here: Tor may have already closed it and the
  // fd number could have been re-used by the time we get here. On iOS 18,
  // attempting to close a re-used guarded fd can trigger EXC_GUARD. Treat the
  // tor-side end as owned by Tor and simply forget our reference.
  owning_fd_tor = -1;
  return (void*)(intptr_t)rc;
}

static int build_cfg(tor_main_configuration_t **out_cfg) {
  tor_main_configuration_t *cfg = tor_main_configuration_new();
  if (!cfg) return -1;

  // Create a private socketpair; give one end to tor as its owning controller
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
    tor_main_configuration_free(cfg);
    return -2;
  }
  owning_fd_app = sv[0];
  owning_fd_tor = sv[1];

  snprintf(fd_arg_copy, sizeof(fd_arg_copy), "%d", owning_fd_tor);

  // Preferred: configure via command-line to avoid stale torrc issues
  const char *args[] = {
    "tor",
    "--DataDirectory", data_dir_copy,
    "--ClientOnly", "1",
    "--SocksPort", socks_arg_copy,
    "--ControlPort", control_arg_copy,
    "--CookieAuthentication", "1",
    "--AvoidDiskWrites", "1",
    "--MaxClientCircuitsPending", "8",
    "--__OwningControllerFD", fd_arg_copy,
    // Make client shutdown fast; don't linger
    "--ShutdownWaitLength", "0",
    NULL
  };
  int argc = 0; while (args[argc]) argc++;

  // Allocate a stable argv array as required by tor_api.h
  char **argv = (char **)malloc(sizeof(char*) * (argc + 1));
  if (!argv) {
    tor_main_configuration_free(cfg);
    close(owning_fd_app); close(owning_fd_tor);
    owning_fd_app = owning_fd_tor = -1;
    return -3;
  }
  for (int i = 0; i <= argc; ++i) argv[i] = (char *)args[i];
  argv_owned = argv;
  argv_owned_argc = argc;

  if (tor_main_configuration_set_command_line(cfg, argc, argv) != 0) {
    tor_main_configuration_free(cfg);
    free(argv);
    close(owning_fd_app); close(owning_fd_tor);
    owning_fd_app = owning_fd_tor = -1;
    return -3;
  }

  *out_cfg = cfg;
  return 0;
}

// Starts tor in a dedicated thread using Tor's embedding API.
// - data_dir: absolute path to DataDirectory
// - socks_addr: e.g., "127.0.0.1:39050"
// - control_addr: e.g., "127.0.0.1:39051"
// - shutdown_fast: if nonzero, we configure a faster shutdown (already default here)
int tor_host_start(const char *data_dir, const char *socks_addr, const char *control_addr, int shutdown_fast) {
  if (!data_dir || !socks_addr || !control_addr) return -1;
  if (strlen(data_dir) >= sizeof(data_dir_copy) || strlen(socks_addr) >= sizeof(socks_arg_copy) || strlen(control_addr) >= sizeof(control_arg_copy))
    return -2;

  // Don't start if an instance appears to be running
  if (owning_fd_app != -1 || owning_fd_tor != -1) return -3;

  // Store copies for potential restart
  strncpy(data_dir_copy, data_dir, sizeof(data_dir_copy)-1);
  data_dir_copy[sizeof(data_dir_copy)-1] = '\0';
  strncpy(socks_arg_copy, socks_addr, sizeof(socks_arg_copy)-1);
  socks_arg_copy[sizeof(socks_arg_copy)-1] = '\0';
  strncpy(control_arg_copy, control_addr, sizeof(control_arg_copy)-1);
  control_arg_copy[sizeof(control_arg_copy)-1] = '\0';

  tor_main_configuration_t *cfg = NULL;
  int rc = build_cfg(&cfg);
  if (rc != 0) return rc;

  (void)shutdown_fast; // already configured via argv

  int prc = pthread_create(&tor_thread, NULL, tor_thread_main, cfg);
  if (prc != 0) {
    tor_main_configuration_free(cfg);
    if (argv_owned) { free(argv_owned); argv_owned = NULL; argv_owned_argc = 0; }
    close(owning_fd_app); close(owning_fd_tor);
    owning_fd_app = owning_fd_tor = -1;
    return -4;
  }
  tor_thread_started = 1;
  return 0;
}

// Triggers a clean shutdown by closing the app-side owning controller fd,
// then joins the tor thread to ensure complete exit before returning.
int tor_host_shutdown(void) {
  if (owning_fd_app != -1) { close(owning_fd_app); owning_fd_app = -1; }
  void *ret = NULL;
  if (tor_thread_started) {
    // Wait for tor_run_main to return
    pthread_join(tor_thread, &ret);
    tor_thread_started = 0;
  }
  return (int)(intptr_t)ret;
}

// Convenience: shutdown then start again with the stored parameters.
int tor_host_restart(const char *data_dir, const char *socks_addr, const char *control_addr, int shutdown_fast) {
  (void)data_dir; (void)socks_addr; (void)control_addr; (void)shutdown_fast;
  // If caller provided new args, refresh our copies
  if (data_dir && data_dir[0]) {
    strncpy(data_dir_copy, data_dir, sizeof(data_dir_copy)-1);
    data_dir_copy[sizeof(data_dir_copy)-1] = '\0';
  }
  if (socks_addr && socks_addr[0]) {
    strncpy(socks_arg_copy, socks_addr, sizeof(socks_arg_copy)-1);
    socks_arg_copy[sizeof(socks_arg_copy)-1] = '\0';
  }
  if (control_addr && control_addr[0]) {
    strncpy(control_arg_copy, control_addr, sizeof(control_arg_copy)-1);
    control_arg_copy[sizeof(control_arg_copy)-1] = '\0';
  }
  (void)tor_host_shutdown();
  return tor_host_start(data_dir_copy, socks_arg_copy, control_arg_copy, shutdown_fast);
}
