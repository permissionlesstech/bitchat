#ifndef ARTI_H
#define ARTI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Start Arti with a SOCKS5 proxy.
 *
 * @param data_dir Path to data directory for Tor state (C string)
 * @param socks_port Port for SOCKS5 proxy (e.g., 39050)
 * @return 0 on success, negative on error:
 *         -1: already running
 *         -2: invalid data_dir
 *         -3: runtime initialization failed
 *         -4: bootstrap failed
 */
int32_t arti_start(const char *data_dir, uint16_t socks_port);

/**
 * Stop Arti gracefully.
 *
 * @return 0 on success, -1 if not running
 */
int32_t arti_stop(void);

/**
 * Check if Arti is currently running.
 *
 * @return 1 if running, 0 if not running
 */
int32_t arti_is_running(void);

/**
 * Get the current bootstrap progress (0-100).
 *
 * @return Progress percentage
 */
int32_t arti_bootstrap_progress(void);

/**
 * Get the current bootstrap summary string.
 *
 * @param buf Buffer to write the summary into
 * @param len Length of the buffer
 * @return Number of bytes written, -1 on error
 */
int32_t arti_bootstrap_summary(char *buf, int32_t len);

/**
 * Signal Arti to go dormant (reduce resource usage).
 *
 * @return 0 on success, -1 if not running
 */
int32_t arti_go_dormant(void);

/**
 * Signal Arti to wake from dormant mode.
 *
 * @return 0 on success, -1 if not running
 */
int32_t arti_wake(void);

#ifdef __cplusplus
}
#endif

#endif /* ARTI_H */
