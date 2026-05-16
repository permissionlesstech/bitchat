//! arti-bitchat: Minimal FFI wrapper around arti-client for BitChat
//!
//! Provides a C-compatible interface for embedding Arti (Rust Tor) in iOS/macOS apps.
//! Exposes a SOCKS5 proxy on localhost that Swift code can route traffic through.

use std::ffi::{c_char, c_int, CStr};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
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
    // Check if already running
    if IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    // Parse data directory
    let data_path = match unsafe { CStr::from_ptr(data_dir) }.to_str() {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -2,
    };

    // Initialize runtime if needed
    if let Err(_) = init_state() {
        return -3;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -3,
    };

    let mut guard = match state.lock() {
        Ok(g) => g,
        Err(_) => return -3,
    };

    // Create shutdown channel
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    guard.shutdown_tx = Some(shutdown_tx);

    let socks_addr: SocketAddr = format!("127.0.0.1:{}", socks_port)
        .parse()
        .expect("valid addr");

    // Spawn the main Arti task
    let data_path_clone = data_path.clone();
    guard.runtime.spawn(async move {
        match run_arti(data_path_clone, socks_addr, shutdown_rx).await {
            Ok(_) => {
                tracing::info!("Arti shutdown cleanly");
            }
            Err(e) => {
                tracing::error!("Arti error: {}", e);
                update_summary(&format!("Error: {}", e));
            }
        }
        IS_RUNNING.store(false, Ordering::SeqCst);
        BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    });

    IS_RUNNING.store(true, Ordering::SeqCst);
    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    update_summary("Starting...");

    0
}

/// Stop Arti gracefully.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_stop() -> c_int {
    if !IS_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }

    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -1,
    };

    let mut guard = match state.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };

    // Send shutdown signal
    if let Some(tx) = guard.shutdown_tx.take() {
        let _ = tx.send(());
    }

    // Clear client reference
    guard.client = None;

    // Give async tasks time to complete
    std::thread::sleep(std::time::Duration::from_millis(200));

    IS_RUNNING.store(false, Ordering::SeqCst);
    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    update_summary("");

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
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Ensure data directory exists
    std::fs::create_dir_all(&data_dir)?;

    update_summary("Configuring...");

    // Build Arti configuration with custom directories
    let cache_dir = data_dir.join("cache");
    let state_dir = data_dir.join("state");

    // Use from_directories which sets up storage correctly
    use arti_client::config::TorClientConfigBuilder;
    let config = TorClientConfigBuilder::from_directories(state_dir, cache_dir)
        .build()?;

    update_summary("Bootstrapping...");

    // Create and bootstrap the Tor client
    let client = TorClient::create_bootstrapped(config).await?;
    let client = Arc::new(client);

    // Store client reference for status queries
    if let Some(state) = ARTI_STATE.get() {
        if let Ok(mut guard) = state.lock() {
            guard.client = Some(client.clone());
        }
    }

    // Mark bootstrap complete
    BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
    update_summary("Ready");

    // Bind SOCKS listener
    let listener = TcpListener::bind(socks_addr).await?;
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

    update_summary("Shutting down...");
    Ok(())
}
