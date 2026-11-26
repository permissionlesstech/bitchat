//! arti-bitchat: Minimal FFI wrapper around arti-client for BitChat
//!
//! Provides a C-compatible interface for embedding Arti (Rust Tor) in iOS/macOS apps.
//! Exposes a SOCKS5 proxy on localhost that Swift code can route traffic through.

use std::ffi::{c_char, c_int, CStr};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use arti_client::TorClient;
use once_cell::sync::OnceCell;
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use tor_rtcompat::PreferredRuntime;

mod socks;

/// Global state for the Arti instance
struct ArtiState {
    /// Tokio runtime (owned, single instance)
    runtime: Runtime,
    /// Shutdown signal sender
    shutdown_tx: Option<oneshot::Sender<()>>,
    /// TorClient handle for status queries
    client: Option<Arc<TorClient<PreferredRuntime>>>,
}

static ARTI_STATE: OnceCell<Mutex<ArtiState>> = OnceCell::new();
static BOOTSTRAP_PROGRESS: AtomicI32 = AtomicI32::new(0);
static IS_RUNNING: AtomicBool = AtomicBool::new(false);
static RUN_GENERATION: AtomicU64 = AtomicU64::new(0);
static BOOTSTRAP_SUMMARY: Mutex<String> = Mutex::new(String::new());

/// Initialize the global state with a new runtime
fn init_state() -> Result<(), &'static str> {
    ARTI_STATE.get_or_try_init(|| -> Result<Mutex<ArtiState>, &'static str> {
        let runtime = Runtime::new().map_err(|_| "Failed to create tokio runtime")?;
        Ok(Mutex::new(ArtiState {
            runtime,
            shutdown_tx: None,
            client: None,
        }))
    })?;
    Ok(())
}

/// Start Arti with a SOCKS5 proxy.
///
/// # Arguments
/// * `data_dir` - Path to data directory for Tor state (C string)
/// * `socks_port` - Port for SOCKS5 proxy (e.g., 39050)
///
/// # Returns
/// * 0 on success
/// * -1 if already running
/// * -2 if data_dir is invalid
/// * -3 if runtime initialization failed
/// * -4 if bootstrap failed
#[no_mangle]
pub extern "C" fn arti_start(data_dir: *const c_char, socks_port: u16) -> c_int {
    // Parse data directory before claiming IS_RUNNING so invalid calls never
    // perturb lifecycle state.
    if data_dir.is_null() {
        return -2;
    }
    let data_path = match unsafe { CStr::from_ptr(data_dir) }.to_str() {
        Ok(s) if !s.is_empty() => PathBuf::from(s),
        _ => return -2,
    };

    // Atomically claim the running slot to eliminate TOCTOU races between
    // concurrent callers and prevent a late store(true) from clobbering a
    // fast task exit.
    if IS_RUNNING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return -1;
    }

    // Initialize runtime if needed
    if init_state().is_err() {
        IS_RUNNING.store(false, Ordering::SeqCst);
        return -3;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => {
            IS_RUNNING.store(false, Ordering::SeqCst);
            return -3;
        }
    };

    let mut guard = match state.lock() {
        Ok(g) => g,
        Err(_) => {
            IS_RUNNING.store(false, Ordering::SeqCst);
            return -3;
        }
    };

    // Fence this run with a monotonic generation so an exiting task from an
    // earlier start cannot clear IS_RUNNING or client state for a newer run.
    let generation = RUN_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;

    // Create shutdown channel
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    guard.shutdown_tx = Some(shutdown_tx);
    guard.client = None;

    let socks_addr: SocketAddr = format!("127.0.0.1:{}", socks_port)
        .parse()
        .expect("valid addr");

    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    update_summary("Starting...");

    // Spawn the main Arti task
    let data_path_clone = data_path.clone();
    guard.runtime.spawn(async move {
        match run_arti(data_path_clone, socks_addr, shutdown_rx, generation).await {
            Ok(_) => {
                tracing::info!("Arti shutdown cleanly");
            }
            Err(e) => {
                tracing::error!("Arti error: {}", e);
                if RUN_GENERATION.load(Ordering::SeqCst) == generation {
                    update_summary(&format!("Error: {}", e));
                }
            }
        }
        if RUN_GENERATION.load(Ordering::SeqCst) == generation {
            if let Some(state) = ARTI_STATE.get() {
                if let Ok(mut guard) = state.lock() {
                    if RUN_GENERATION.load(Ordering::SeqCst) == generation {
                        guard.client = None;
                        guard.shutdown_tx = None;
                    }
                }
            }
            IS_RUNNING.store(false, Ordering::SeqCst);
            BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
        }
    });

    0
}

/// Stop Arti gracefully.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_stop() -> c_int {
    if IS_RUNNING
        .compare_exchange(true, false, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return -1;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -1,
    };

    {
        let mut guard = match state.lock() {
            Ok(g) => g,
            Err(_) => return -1,
        };

        // Advance generation before signaling shutdown so the exiting task
        // cannot race with a subsequent restart.
        RUN_GENERATION.fetch_add(1, Ordering::SeqCst);

        // Send shutdown signal
        if let Some(tx) = guard.shutdown_tx.take() {
            let _ = tx.send(());
        }

        // Clear client reference
        guard.client = None;
    }

    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    update_summary("");

    // Give async tasks time to unwind outside the state lock
    std::thread::sleep(std::time::Duration::from_millis(200));

    0
}

/// Check if Arti is currently running.
///
/// # Returns
/// * 1 if running
/// * 0 if not running
#[no_mangle]
pub extern "C" fn arti_is_running() -> c_int {
    if IS_RUNNING.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Get the current bootstrap progress (0-100).
#[no_mangle]
pub extern "C" fn arti_bootstrap_progress() -> c_int {
    BOOTSTRAP_PROGRESS.load(Ordering::SeqCst)
}

/// Get the current bootstrap summary string.
///
/// # Arguments
/// * `buf` - Buffer to write the summary into
/// * `len` - Length of the buffer
///
/// # Returns
/// * Number of bytes written (not including null terminator)
/// * -1 if buffer is null or too small
#[no_mangle]
pub extern "C" fn arti_bootstrap_summary(buf: *mut c_char, len: c_int) -> c_int {
    if buf.is_null() || len <= 0 {
        return -1;
    }

    let summary = match BOOTSTRAP_SUMMARY.lock() {
        Ok(s) => s.clone(),
        Err(_) => return -1,
    };

    let bytes = summary.as_bytes();
    let copy_len = std::cmp::min(bytes.len(), (len - 1) as usize);

    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
        *buf.add(copy_len) = 0; // null terminator
    }

    copy_len as c_int
}

/// Signal Arti to go dormant (reduce resource usage).
/// This is a hint; Arti may not fully support dormant mode yet.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_go_dormant() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }
    // Arti doesn't have explicit dormant mode yet, but we can note the intent
    update_summary("Dormant");
    0
}

/// Signal Arti to wake from dormant mode.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_wake() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }
    update_summary("Active");
    0
}

fn update_summary(s: &str) {
    if let Ok(mut guard) = BOOTSTRAP_SUMMARY.lock() {
        guard.clear();
        guard.push_str(s);
    }
}

/// Main async entry point for Arti
async fn run_arti(
    data_dir: PathBuf,
    socks_addr: SocketAddr,
    mut shutdown_rx: oneshot::Receiver<()>,
    generation: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Ensure data directory exists
    std::fs::create_dir_all(&data_dir)?;

    if RUN_GENERATION.load(Ordering::SeqCst) != generation {
        return Ok(());
    }
    update_summary("Configuring...");

    // Build Arti configuration with custom directories and onion-service routing enabled
    let config = build_tor_config(&data_dir)?;

    if RUN_GENERATION.load(Ordering::SeqCst) != generation {
        return Ok(());
    }
    update_summary("Bootstrapping...");

    // Create and bootstrap the Tor client while honoring arti_stop() immediately
    let client = tokio::select! {
        res = TorClient::create_bootstrapped(config) => res?,
        _ = &mut shutdown_rx => {
            tracing::info!("Shutdown signal received during bootstrap");
            return Ok(());
        }
    };
    let client = Arc::new(client);

    // Store client reference for status queries only if this run is still active
    if let Some(state) = ARTI_STATE.get() {
        if let Ok(mut guard) = state.lock() {
            if RUN_GENERATION.load(Ordering::SeqCst) != generation {
                return Ok(());
            }
            guard.client = Some(client.clone());
        }
    }

    // Bind SOCKS listener while still observing shutdown
    let listener = tokio::select! {
        res = TcpListener::bind(socks_addr) => res?,
        _ = &mut shutdown_rx => {
            tracing::info!("Shutdown signal received before SOCKS bind");
            return Ok(());
        }
    };

    if RUN_GENERATION.load(Ordering::SeqCst) != generation {
        return Ok(());
    }

    // Mark bootstrap complete after SOCKS listener is bound
    BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
    update_summary("Ready");
    tracing::info!("SOCKS5 proxy listening on {}", socks_addr);

    // Accept connections until shutdown
    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                match accept_result {
                    Ok((stream, peer_addr)) => {
                        let client = client.clone();
                        tokio::spawn(async move {
                            if let Err(e) = socks::handle_socks_connection(stream, peer_addr, client).await {
                                tracing::debug!("SOCKS connection error from {}: {}", peer_addr, e);
                            }
                        });
                    }
                    Err(e) => {
                        tracing::warn!("Accept error: {}", e);
                    }
                }
            }
            _ = &mut shutdown_rx => {
                tracing::info!("Shutdown signal received");
                break;
            }
        }
    }

    if RUN_GENERATION.load(Ordering::SeqCst) == generation {
        update_summary("Shutting down...");
    }
    Ok(())
}

fn build_tor_config(
    data_dir: &std::path::Path,
) -> Result<arti_client::TorClientConfig, arti_client::config::ConfigBuildError> {
    use arti_client::config::TorClientConfigBuilder;

    let cache_dir = data_dir.join("cache");
    let state_dir = data_dir.join("state");

    let mut builder = TorClientConfigBuilder::from_directories(state_dir, cache_dir);
    builder.address_filter().allow_onion_addrs(true);
    builder.build()
}

#[cfg(test)]
mod tests {
    use super::*;
    use arti_client::IntoTorAddr;
    use std::ffi::CString;

    #[test]
    fn tor_config_enables_onion_addresses() {
        let dir = std::env::temp_dir().join("arti-bitchat-onion-config-test");
        let config = build_tor_config(&dir).expect("TorClientConfig should build");
        let debug = format!("{config:?}");
        assert!(
            debug.contains("allow_onion_addrs: true"),
            "onion addresses must be allowed for custom .onion Nostr relays; got: {debug}"
        );
    }

    #[test]
    fn onion_v3_relay_address_parses_as_tor_addr() {
        // Synthetic valid-syntax v3 onion hostname (56 base32 chars).
        let addr = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion:443";
        assert!(addr.into_tor_addr().is_ok());
    }

    static FFI_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn arti_start_rejects_null_and_empty_data_dir_without_setting_running() {
        let _guard = FFI_TEST_LOCK.lock().unwrap();
        assert_eq!(arti_start(std::ptr::null(), 39050), -2);
        let empty = CString::new("").unwrap();
        assert_eq!(arti_start(empty.as_ptr(), 39050), -2);
        assert_eq!(arti_is_running(), 0);
        assert_eq!(arti_stop(), -1);
    }

    #[test]
    fn arti_start_atomic_cas_and_stop_interrupts_bootstrap() {
        let _guard = FFI_TEST_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join("arti-bitchat-lifecycle-test");
        let c_dir = CString::new(dir.to_string_lossy().as_ref()).unwrap();

        assert_eq!(arti_start(c_dir.as_ptr(), 0), 0);
        assert_eq!(arti_is_running(), 1);
        // Second concurrent start must be rejected atomically.
        assert_eq!(arti_start(c_dir.as_ptr(), 0), -1);

        // Stop must interrupt in-flight bootstrap cleanly and reset state.
        assert_eq!(arti_stop(), 0);
        assert_eq!(arti_is_running(), 0);
        assert_eq!(arti_stop(), -1);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
