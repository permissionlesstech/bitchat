#ifndef ARTI_H
#define ARTI_H

#include <stdint.h>
#include <stdbool.h>

/**
 * Start Arti with a SOCKS5 proxy.
 *
 * # Arguments
 * * `data_dir` - Path to data directory for Tor state (C string)
 * * `socks_port` - Port for SOCKS5 proxy (e.g., 39050)
 *
 * # Returns
 * * 0 on success
 * * -1 if already running
 * * -2 if data_dir is invalid
 * * -3 if runtime initialization failed
 * * -4 if bootstrap failed
 */
int arti_start(const char *data_dir, uint16_t socks_port);

/**
 * Start Arti with a versioned JSON transport configuration.
 *
 * The JSON is deliberately small and bounded by the Swift caller.  It carries
 * only the selected route, validated bridge lines, and IPtProxy's loopback
 * SOCKS endpoint.  Application payload destinations never pass through this
 * interface.
 */
int arti_start_with_config(const char *data_dir, uint16_t socks_port, const char *config_json);

/**
 * Validate transport JSON and bridge lines without starting network work.
 *
 * Returns zero for a supported configuration and `-5` for any invalid input.
 * Detailed parser failures are intentionally not returned across FFI because
 * bridge material must not leak into diagnostics.
 */
int arti_validate_transport_config(const char *config_json);

/**
 * Stop Arti gracefully.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_stop(void);

/**
 * Check if Arti is currently running.
 *
 * # Returns
 * * 1 if running
 * * 0 if not running
 */
int arti_is_running(void);

/**
 * Get the current bootstrap progress (0-100).
 */
int arti_bootstrap_progress(void);

/**
 * Get the current bootstrap summary string.
 *
 * # Arguments
 * * `buf` - Buffer to write the summary into
 * * `len` - Length of the buffer
 *
 * # Returns
 * * Number of bytes written (not including null terminator)
 * * -1 if buffer is null or too small
 */
int arti_bootstrap_summary(char *buf, int len);

/**
 * Signal Arti to go dormant (reduce resource usage).
 * This is a hint; Arti may not fully support dormant mode yet.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_go_dormant(void);

/**
 * Signal Arti to wake from dormant mode.
 *
 * # Returns
 * * 0 on success
 * * -1 if not running
 */
int arti_wake(void);

/**
 * Enable or disable the debug log bridge.
 *
 * Disabling also discards anything still buffered.
 *
 * # Returns
 * * 0 always
 */
int arti_set_diagnostics_enabled(int enabled);

/**
 * Take the oldest buffered diagnostic line.
 *
 * # Arguments
 * * `buf` - Buffer to write the line into
 * * `len` - Length of the buffer
 *
 * # Returns
 * * Number of bytes written (not including null terminator)
 * * -1 if the buffer is unusable or no line is available
 */
int arti_next_diagnostic(char *buf, int len);

#endif  /* ARTI_H */
