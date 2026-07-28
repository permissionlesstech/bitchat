//! arti-bitchat: Minimal FFI wrapper around arti-client for BitChat
//!
//! Provides a C-compatible interface for embedding Arti (Rust Tor) in iOS/macOS apps.
//! Exposes a SOCKS5 proxy on localhost that Swift code can route traffic through.

use std::ffi::{c_char, c_int, CStr};
use std::future::Future;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use arti_client::config::BridgeConfigBuilder;
use arti_client::TorClient;
use once_cell::sync::OnceCell;
use serde::Deserialize;
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tor_rtcompat::PreferredRuntime;

mod diagnostics;
mod socks;
mod transport_monitor;

const TRANSPORT_CONFIG_VERSION: u8 = 1;
const MAX_TRANSPORT_CONFIG_BYTES: usize = 32 * 1024;
const MAX_BRIDGES: usize = 8;
const BOOTSTRAP_PROGRESS_INTERVAL: std::time::Duration = std::time::Duration::from_millis(500);
/// Ceiling on SOCKS sessions the local listener will carry at once.
///
/// Loopback on iOS is not sandboxed per app, so this listener is reachable by
/// anything else on the device. The app itself needs a relay socket per relay
/// plus the directory fetch, so this is far above normal use and only bounds
/// what an outside caller can pin.
const MAX_CONCURRENT_SOCKS_SESSIONS: usize = 64;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
enum TransportKind {
    Direct,
    Obfs4,
    Snowflake,
}

impl TransportKind {
    fn protocol_name(self) -> Option<&'static str> {
        match self {
            Self::Direct => None,
            Self::Obfs4 => Some("obfs4"),
            Self::Snowflake => Some("snowflake"),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TransportConfig {
    version: u8,
    transport: TransportKind,
    #[serde(default)]
    bridge_lines: Vec<String>,
    pt_socks_address: Option<SocketAddr>,
}

#[derive(Clone, Debug)]
enum PreparedTransport {
    Direct,
    Pluggable {
        protocol: TransportKind,
        socks_address: SocketAddr,
        bridges: Vec<BridgeConfigBuilder>,
    },
}

impl TransportConfig {
    fn prepare(self) -> Result<PreparedTransport, String> {
        if self.version != TRANSPORT_CONFIG_VERSION {
            return Err("unsupported transport configuration version".into());
        }

        match self.transport.protocol_name() {
            None => {
                if !self.bridge_lines.is_empty() || self.pt_socks_address.is_some() {
                    return Err("direct transport cannot contain bridge settings".into());
                }
                Ok(PreparedTransport::Direct)
            }
            Some(protocol) => {
                if self.bridge_lines.is_empty() || self.bridge_lines.len() > MAX_BRIDGES {
                    return Err("pluggable transport requires one to eight bridges".into());
                }
                let socks_address = self
                    .pt_socks_address
                    .ok_or_else(|| "pluggable transport has no local SOCKS address".to_string())?;
                if !socks_address.ip().is_loopback() {
                    return Err("pluggable transport SOCKS address is not loopback".into());
                }
                let bridges = self
                    .bridge_lines
                    .iter()
                    .enumerate()
                    .map(|(index, line)| {
                        let builder = line
                            .parse::<BridgeConfigBuilder>()
                            .map_err(|_| format!("bridge line {} is invalid", index + 1))?;
                        if builder.get_transport() != Some(protocol) || builder.build().is_err() {
                            return Err(format!("bridge line {} is invalid", index + 1));
                        }
                        Ok(builder)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(PreparedTransport::Pluggable {
                    protocol: self.transport,
                    socks_address,
                    bridges,
                })
            }
        }
    }
}

/// Global state for the Arti instance
struct ArtiState {
    /// Tokio runtime (owned, single instance)
    runtime: Runtime,
    /// Shutdown signal sender
    shutdown_tx: Option<oneshot::Sender<()>>,
    /// Handle for the currently owned attempt. Stop joins this before a new
    /// attempt is allowed to start.
    task: Option<JoinHandle<()>>,
    /// TorClient handle for status queries
    client: Option<Arc<TorClient<PreferredRuntime>>>,
}

static ARTI_STATE: OnceCell<Mutex<ArtiState>> = OnceCell::new();
static BOOTSTRAP_PROGRESS: AtomicI32 = AtomicI32::new(0);
static IS_RUNNING: AtomicBool = AtomicBool::new(false);
static BOOTSTRAP_SUMMARY: Mutex<String> = Mutex::new(String::new());
static TRANSPORT_STAGE: AtomicI32 = AtomicI32::new(0);
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);
static ACTIVE_GENERATION: AtomicU64 = AtomicU64::new(0);

/// Initialize the global state with a new runtime
fn init_state() -> Result<(), &'static str> {
    // Installed unconditionally so that enabling diagnostics later still takes
    // effect. It stays inert, and callsites stay cached as uninteresting,
    // until the host opts in.
    diagnostics::install();
    ARTI_STATE.get_or_try_init(|| -> Result<Mutex<ArtiState>, &'static str> {
        let runtime = Runtime::new().map_err(|_| "Failed to create tokio runtime")?;
        Ok(Mutex::new(ArtiState {
            runtime,
            shutdown_tx: None,
            task: None,
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
    start_arti(data_dir, socks_port, PreparedTransport::Direct)
}

/// Start Arti with a versioned JSON transport configuration.
///
/// The JSON is deliberately small and bounded by the Swift caller.  It carries
/// only the selected route, validated bridge lines, and IPtProxy's loopback
/// SOCKS endpoint.  Application payload destinations never pass through this
/// interface.
#[no_mangle]
pub extern "C" fn arti_start_with_config(
    data_dir: *const c_char,
    socks_port: u16,
    config_json: *const c_char,
) -> c_int {
    let prepared = match parse_and_validate_transport_config(config_json) {
        Ok(config) => config,
        Err(_) => return -5,
    };
    start_arti(data_dir, socks_port, prepared)
}

/// Validate transport JSON and bridge lines without starting network work.
///
/// Returns zero for a supported configuration and `-5` for any invalid input.
/// Detailed parser failures are intentionally not returned across FFI because
/// bridge material must not leak into diagnostics.
#[no_mangle]
pub extern "C" fn arti_validate_transport_config(config_json: *const c_char) -> c_int {
    match parse_and_validate_transport_config(config_json) {
        Ok(_) => 0,
        Err(_) => -5,
    }
}

fn parse_and_validate_transport_config(
    config_json: *const c_char,
) -> Result<PreparedTransport, String> {
    let prepared = parse_transport_config(config_json)?;
    build_client_config(
        PathBuf::from("/arti-validation/state"),
        PathBuf::from("/arti-validation/cache"),
        &prepared,
    )
    .map_err(|_| "transport configuration is not supported".to_string())?;
    Ok(prepared)
}

fn parse_transport_config(config_json: *const c_char) -> Result<PreparedTransport, String> {
    if config_json.is_null() {
        return Err("transport configuration is null".into());
    }
    let bytes = unsafe { CStr::from_ptr(config_json) }.to_bytes();
    if bytes.is_empty() || bytes.len() > MAX_TRANSPORT_CONFIG_BYTES {
        return Err("transport configuration size is invalid".into());
    }
    let config: TransportConfig =
        serde_json::from_slice(bytes).map_err(|_| "transport configuration is invalid")?;
    config.prepare()
}

fn start_arti(data_dir: *const c_char, socks_port: u16, transport: PreparedTransport) -> c_int {
    // Parse data directory
    if data_dir.is_null() {
        return -2;
    }
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

    // A completed attempt can leave a finished JoinHandle until the next FFI
    // call. An unfinished handle is authoritative even if a stale status flag
    // says otherwise.
    if guard.task.as_ref().is_some_and(|task| !task.is_finished()) {
        return -1;
    }
    guard.task.take();
    if IS_RUNNING.swap(true, Ordering::SeqCst) {
        IS_RUNNING.store(true, Ordering::SeqCst);
        return -1;
    }

    let generation = NEXT_GENERATION.fetch_add(1, Ordering::SeqCst);
    ACTIVE_GENERATION.store(generation, Ordering::SeqCst);

    // Create shutdown channel
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    guard.shutdown_tx = Some(shutdown_tx);

    let socks_addr: SocketAddr = format!("127.0.0.1:{}", socks_port)
        .parse()
        .expect("valid addr");

    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    TRANSPORT_STAGE.store(0, Ordering::SeqCst);
    update_summary("Starting...");

    // Spawn the main Arti task. Only the active generation may clear global
    // status, so a late completion can never overwrite a newer attempt.
    let data_path_clone = data_path.clone();
    let task = guard.runtime.spawn(async move {
        match run_arti(data_path_clone, socks_addr, transport, shutdown_rx).await {
            Ok(_) => {
                tracing::info!("Arti shutdown cleanly");
            }
            Err(_) => {
                tracing::error!("Arti failed during {}", current_phase());
                update_summary(safe_failure_summary());
            }
        }
        finish_attempt_if_current(generation);
    });
    guard.task = Some(task);

    0
}

/// Stop Arti gracefully.
///
/// # Returns
/// * 0 on success
/// * -1 if not running
#[no_mangle]
pub extern "C" fn arti_stop() -> c_int {
    let state = match ARTI_STATE.get() {
        Some(s) => s,
        None => return -1,
    };

    let (shutdown_tx, task, runtime_handle, generation) = {
        let mut guard = match state.lock() {
            Ok(g) => g,
            Err(_) => return -1,
        };
        let has_attempt = guard.shutdown_tx.is_some() || guard.task.is_some();
        if !has_attempt {
            return -1;
        }
        let runtime_handle = guard.runtime.handle().clone();
        let generation = ACTIVE_GENERATION.load(Ordering::SeqCst);
        guard.client = None;
        (
            guard.shutdown_tx.take(),
            guard.task.take(),
            runtime_handle,
            generation,
        )
    };

    // Cancelling the outer lifecycle future drops an in-progress
    // create_bootstrapped() call as well as its transport manager.
    if let Some(tx) = shutdown_tx {
        let _ = tx.send(());
    }

    // Do not report stopped until the owning task has actually exited. This is
    // what prevents the next Swift start from overlapping the previous Arti
    // bootstrap.
    if let Some(task) = task {
        let _ = runtime_handle.block_on(task);
    }
    finish_attempt_if_current(generation);
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

fn advance_transport_stage(stage: i32, summary: &'static str) {
    let mut current = TRANSPORT_STAGE.load(Ordering::SeqCst);
    while stage > current {
        match TRANSPORT_STAGE.compare_exchange(current, stage, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => {
                update_summary(summary);
                return;
            }
            Err(actual) => current = actual,
        }
    }
}

fn current_phase() -> String {
    BOOTSTRAP_SUMMARY
        .lock()
        .map(|summary| summary.clone())
        .unwrap_or_default()
}

fn safe_failure_summary() -> &'static str {
    match current_phase().as_str() {
        "Configuring..." => "Error: Tor configuration failed",
        "Ready" => "Error: local SOCKS listener failed",
        _ => "Error: Tor bootstrap failed",
    }
}

fn finish_generation(active: &AtomicU64, generation: u64) -> bool {
    active
        .compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
}

fn finish_attempt_if_current(generation: u64) {
    if !finish_generation(&ACTIVE_GENERATION, generation) {
        return;
    }
    IS_RUNNING.store(false, Ordering::SeqCst);
    BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    if let Some(state) = ARTI_STATE.get() {
        if let Ok(mut guard) = state.lock() {
            guard.shutdown_tx = None;
            guard.client = None;
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
enum Cancellable<T> {
    Completed(T),
    Cancelled,
}

async fn await_or_cancel<F, T>(future: F, mut shutdown_rx: oneshot::Receiver<()>) -> Cancellable<T>
where
    F: Future<Output = T>,
{
    tokio::pin!(future);
    tokio::select! {
        biased;
        _ = &mut shutdown_rx => Cancellable::Cancelled,
        result = &mut future => Cancellable::Completed(result),
    }
}

/// Main async entry point for Arti
async fn run_arti(
    data_dir: PathBuf,
    socks_addr: SocketAddr,
    transport: PreparedTransport,
    shutdown_rx: oneshot::Receiver<()>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    match await_or_cancel(
        run_arti_lifecycle(data_dir, socks_addr, transport),
        shutdown_rx,
    )
    .await
    {
        Cancellable::Completed(result) => result,
        Cancellable::Cancelled => {
            update_summary("Stopping...");
            Ok(())
        }
    }
}

async fn run_arti_lifecycle(
    data_dir: PathBuf,
    socks_addr: SocketAddr,
    transport: PreparedTransport,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Ensure data directory exists
    std::fs::create_dir_all(&data_dir)?;

    update_summary("Configuring...");

    // Build Arti configuration with custom directories
    let cache_dir = data_dir.join("cache");
    let state_dir = data_dir.join("state");

    let mut configured_transport = transport.clone();
    let transport_monitor =
        if let PreparedTransport::Pluggable { socks_address, .. } = &mut configured_transport {
            let monitor = transport_monitor::start(*socks_address).await?;
            *socks_address = monitor.local_address;
            Some(monitor)
        } else {
            None
        };
    let uses_pluggable_transport =
        matches!(configured_transport, PreparedTransport::Pluggable { .. });
    let config = build_client_config(state_dir, cache_dir, &configured_transport)?;
    if uses_pluggable_transport {
        update_summary("Transport proxy configured");
    } else {
        update_summary("Bootstrapping...");
    }

    // Create and bootstrap the Tor client. Bootstrapping is driven explicitly
    // rather than through `create_bootstrapped` so that real progress can be
    // reported while it runs. `BOOTSTRAP_PROGRESS` previously only ever held 0
    // or 100, which made a slow route indistinguishable from a blocked one and
    // led the host to blame the network for a bootstrap that was still
    // advancing.
    let client = Arc::new(TorClient::builder().config(config).create_unbootstrapped()?);
    let progress_source = client.clone();
    tokio::select! {
        result = client.bootstrap() => result,
        never = report_bootstrap_progress(move || {
            (progress_source.bootstrap_status().as_frac() * 100.0).round() as i32
        }) => match never {},
    }?;
    let _transport_monitor = transport_monitor;

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

    // Accept connections until the outer lifecycle future is cancelled.
    let session_slots = Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_SOCKS_SESSIONS));
    loop {
        match listener.accept().await {
            Ok((stream, peer_addr)) => {
                // Refusing loudly at the ceiling beats queueing: a caller that
                // holds this many sessions open is not the app doing its work.
                let Ok(slot) = session_slots.clone().try_acquire_owned() else {
                    tracing::warn!("Refused SOCKS connection: session limit reached");
                    drop(stream);
                    continue;
                };
                let client = client.clone();
                tokio::spawn(async move {
                    if let Err(e) = socks::handle_socks_connection(stream, peer_addr, client).await
                    {
                        tracing::debug!("SOCKS connection error from {}: {}", peer_addr, e);
                    }
                    drop(slot);
                });
            }
            Err(e) => {
                tracing::warn!("Accept error: {}", e);
            }
        }
    }
}

/// Publish bootstrap progress until whatever is racing this stops polling it.
///
/// Deliberately not a spawned task. Cancelling the lifecycle future has to stop
/// this too: a detached reporter outlived the bootstrap it was reporting on,
/// held the abandoned client alive, and went on overwriting the progress the
/// next route was publishing. Every auto-fallback hop cancels a bootstrap, so
/// that leak landed on exactly the path that needs progress to be trustworthy.
async fn report_bootstrap_progress<F>(read_percent: F) -> std::convert::Infallible
where
    F: Fn() -> i32,
{
    loop {
        // Held below 100 because the host treats 100 as "ready", and the
        // fraction reaches 1.0 before `bootstrap` returns.
        BOOTSTRAP_PROGRESS.store(read_percent().clamp(0, 99), Ordering::SeqCst);
        tokio::time::sleep(BOOTSTRAP_PROGRESS_INTERVAL).await;
    }
}

fn build_client_config(
    state_dir: PathBuf,
    cache_dir: PathBuf,
    transport: &PreparedTransport,
) -> Result<arti_client::TorClientConfig, Box<dyn std::error::Error + Send + Sync>> {
    use arti_client::config::pt::TransportConfigBuilder;
    use arti_client::config::TorClientConfigBuilder;

    let mut config_builder = TorClientConfigBuilder::from_directories(state_dir, cache_dir);
    if let PreparedTransport::Pluggable {
        protocol,
        socks_address,
        bridges,
    } = transport
    {
        config_builder
            .bridges()
            .bridges()
            .extend(bridges.iter().cloned());

        let protocol_name = protocol
            .protocol_name()
            .expect("pluggable transport has a protocol");
        let mut transport_builder = TransportConfigBuilder::default();
        transport_builder
            .protocols(vec![protocol_name.parse()?])
            .proxy_addr(*socks_address);
        config_builder
            .bridges()
            .transports()
            .push(transport_builder);
        config_builder
            .bridges()
            .enabled(arti_client::config::BoolOrAuto::Explicit(true));
    }
    Ok(config_builder.build()?)
}

#[cfg(test)]
mod transport_config_tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::atomic::AtomicU64;

    const RSA_ID: &str = "8838024498816A039FCBBAB14E6F40A0843051FA";

    fn parse(json: serde_json::Value) -> Result<PreparedTransport, String> {
        let encoded = CString::new(json.to_string()).expect("JSON has no nulls");
        parse_and_validate_transport_config(encoded.as_ptr())
    }

    #[test]
    fn accepts_bounded_loopback_obfs4_configuration() {
        let bridge = format!(
            "Bridge obfs4 192.0.2.10:443 {} cert=YWJjZA iat-mode=0",
            RSA_ID
        );
        let prepared = parse(serde_json::json!({
            "version": 1,
            "transport": "obfs4",
            "bridgeLines": [bridge],
            "ptSocksAddress": "127.0.0.1:12345"
        }))
        .expect("valid transport configuration");

        assert!(matches!(
            prepared,
            PreparedTransport::Pluggable {
                protocol: TransportKind::Obfs4,
                socks_address,
                bridges
            } if socks_address == "127.0.0.1:12345".parse().unwrap()
                && bridges.len() == 1
        ));
    }

    #[test]
    fn builds_unmanaged_pluggable_transport_configuration() {
        let bridge = format!(
            "Bridge obfs4 192.0.2.10:443 {} cert=YWJjZA iat-mode=0",
            RSA_ID
        );
        let prepared = parse(serde_json::json!({
            "version": 1,
            "transport": "obfs4",
            "bridgeLines": [bridge],
            "ptSocksAddress": "127.0.0.1:12345"
        }))
        .expect("valid transport configuration");
        let root = std::env::temp_dir().join("arti-bitchat-config-test");

        build_client_config(root.join("state"), root.join("cache"), &prepared)
            .expect("unmanaged pluggable transport config");
    }

    #[test]
    fn rejects_non_loopback_transport_listener() {
        let bridge = format!(
            "Bridge obfs4 192.0.2.10:443 {} cert=YWJjZA iat-mode=0",
            RSA_ID
        );
        assert!(parse(serde_json::json!({
            "version": 1,
            "transport": "obfs4",
            "bridgeLines": [bridge],
            "ptSocksAddress": "192.0.2.20:12345"
        }))
        .is_err());
    }

    #[test]
    fn rejects_transport_mismatch_before_starting_network_work() {
        let bridge = format!(
            "Bridge obfs4 192.0.2.10:443 {} cert=YWJjZA iat-mode=0",
            RSA_ID
        );
        assert!(parse(serde_json::json!({
            "version": 1,
            "transport": "snowflake",
            "bridgeLines": [bridge],
            "ptSocksAddress": "[::1]:12345"
        }))
        .is_err());
    }

    #[test]
    fn cancellation_interrupts_pending_bootstrap_work() {
        let runtime = Runtime::new().expect("test runtime");
        runtime.block_on(async {
            let (shutdown_tx, shutdown_rx) = oneshot::channel();
            shutdown_tx.send(()).expect("send cancellation");
            let outcome = await_or_cancel(std::future::pending::<u8>(), shutdown_rx).await;
            assert_eq!(outcome, Cancellable::Cancelled);
        });
    }

    // Reproduces the device stall in isolation. On hardware both obfs4 and
    // Snowflake sat inside create_bootstrapped for their whole deadline while
    // the loopback monitor never accepted a connection, so bootstrap must
    // dial the configured unmanaged proxy for the handoff to exist at all.
    // A fake listener stands in for the transport: it accepts and stays
    // silent, which is enough to observe the dial itself.
    #[test]
    fn bootstrap_dials_the_unmanaged_transport_proxy() {
        let runtime = Runtime::new().expect("test runtime");
        runtime.block_on(async {
            let proxy = TcpListener::bind("127.0.0.1:0")
                .await
                .expect("fake transport proxy");
            let proxy_address = proxy.local_addr().expect("proxy address");

            let bridge = format!(
                "Bridge obfs4 192.0.2.10:443 {} cert=YWJjZA iat-mode=0",
                RSA_ID
            );
            let prepared = parse(serde_json::json!({
                "version": 1,
                "transport": "obfs4",
                "bridgeLines": [bridge],
                "ptSocksAddress": proxy_address.to_string()
            }))
            .expect("valid transport configuration");

            let root = std::env::temp_dir().join("arti-bitchat-dial-test");
            let _ = std::fs::remove_dir_all(&root);
            let config = build_client_config(root.join("state"), root.join("cache"), &prepared)
                .expect("unmanaged pluggable transport config");

            let bootstrap = tokio::spawn(async move {
                let _ = TorClient::create_bootstrapped(config).await;
            });

            let dialed =
                tokio::time::timeout(std::time::Duration::from_secs(30), proxy.accept()).await;
            bootstrap.abort();

            let (_stream, peer) = dialed
                .expect("Arti never dialed the unmanaged transport proxy within 30s")
                .expect("transport proxy accept failed");
            assert!(peer.ip().is_loopback(), "dial came from {}", peer);
        });
    }

    // The dial above uses a synthetic obfs4 line. Snowflake ships longer
    // lines with a different transport name, placeholder TEST-NET addresses,
    // and many parameters, so it has to be proven separately with the exact
    // strings `SnowflakeDefaults.bridgeLines` sends.
    #[test]
    fn bootstrap_dials_the_transport_proxy_for_production_snowflake_bridges() {
        const ICE: &str = "stun:stun.l.google.com:19302,stun:stun.antisip.com:3478,\
             stun:stun.bluesip.net:3478,stun:stun.dus.net:3478,\
             stun:stun.epygi.com:3478,stun:stun.sonetel.com:3478,\
             stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,\
             stun:stun.nextcloud.com:3478,stun:stun.bethesda.net:3478,\
             stun:stun.nextcloud.com:443";
        let bridges = [
            format!(
                "Bridge snowflake 192.0.2.4:80 8838024498816A039FCBBAB14E6F40A0843051FA \
                 fingerprint=8838024498816A039FCBBAB14E6F40A0843051FA \
                 url=https://1098762253.rsc.cdn77.org/ \
                 fronts=www.cdn77.com,www.phpmyadmin.net ice={ICE} \
                 utls-imitate=hellorandomizedalpn"
            ),
            format!(
                "Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 \
                 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 \
                 url=https://1098762253.rsc.cdn77.org/ \
                 fronts=www.cdn77.com,www.phpmyadmin.net ice={ICE} \
                 utls-imitate=hellorandomizedalpn"
            ),
        ];

        let runtime = Runtime::new().expect("test runtime");
        runtime.block_on(async {
            let proxy = TcpListener::bind("127.0.0.1:0")
                .await
                .expect("fake transport proxy");
            let proxy_address = proxy.local_addr().expect("proxy address");

            let prepared = parse(serde_json::json!({
                "version": 1,
                "transport": "snowflake",
                "bridgeLines": bridges,
                "ptSocksAddress": proxy_address.to_string()
            }))
            .expect("production snowflake bridge lines must be accepted");

            let root = std::env::temp_dir().join("arti-bitchat-snowflake-dial-test");
            let _ = std::fs::remove_dir_all(&root);
            let config = build_client_config(root.join("state"), root.join("cache"), &prepared)
                .expect("unmanaged snowflake transport config");

            let bootstrap = tokio::spawn(async move {
                let _ = TorClient::create_bootstrapped(config).await;
            });

            let dialed =
                tokio::time::timeout(std::time::Duration::from_secs(30), proxy.accept()).await;
            bootstrap.abort();

            let (_stream, peer) = dialed
                .expect("Arti never dialed the transport proxy for snowflake within 30s")
                .expect("transport proxy accept failed");
            assert!(peer.ip().is_loopback(), "dial came from {}", peer);
        });
    }

    // The dial above proves Arti reaches a plain listener. This proves the
    // monitor in between actually accepts and forwards: a TCP connect
    // succeeds off the listen backlog even when nothing ever calls accept,
    // so reaching the monitor's port is not evidence that the handoff works.
    #[test]
    fn transport_monitor_forwards_the_bootstrap_dial_upstream() {
        let runtime = Runtime::new().expect("test runtime");
        runtime.block_on(async {
            let upstream = TcpListener::bind("127.0.0.1:0")
                .await
                .expect("fake transport listener");
            let upstream_address = upstream.local_addr().expect("upstream address");

            let monitor = transport_monitor::start(upstream_address)
                .await
                .expect("transport monitor");

            let bridge = format!(
                "Bridge obfs4 192.0.2.10:443 {} cert=YWJjZA iat-mode=0",
                RSA_ID
            );
            let prepared = parse(serde_json::json!({
                "version": 1,
                "transport": "obfs4",
                "bridgeLines": [bridge],
                "ptSocksAddress": monitor.local_address.to_string()
            }))
            .expect("valid transport configuration");

            let root = std::env::temp_dir().join("arti-bitchat-monitor-test");
            let _ = std::fs::remove_dir_all(&root);
            let config = build_client_config(root.join("state"), root.join("cache"), &prepared)
                .expect("unmanaged pluggable transport config");

            let bootstrap = tokio::spawn(async move {
                let _ = TorClient::create_bootstrapped(config).await;
            });

            let forwarded =
                tokio::time::timeout(std::time::Duration::from_secs(30), upstream.accept()).await;
            bootstrap.abort();

            forwarded
                .expect("monitor never forwarded the dial upstream within 30s")
                .expect("upstream accept failed");
            assert_eq!(TRANSPORT_STAGE.load(Ordering::SeqCst), 3);
        });
    }

    // The reporter used to be a detached `tokio::spawn`, so cancelling a
    // bootstrap left it running: it held the abandoned client alive and kept
    // writing progress that the next route then read as its own. Every
    // auto-fallback hop cancels a bootstrap, so it has to stop with one.
    #[test]
    fn cancelling_the_bootstrap_stops_the_progress_reporter() {
        let runtime = Runtime::new().expect("test runtime");
        runtime.block_on(async {
            let ticks = Arc::new(AtomicI32::new(0));
            let counted = ticks.clone();
            tokio::select! {
                _ = tokio::time::sleep(std::time::Duration::from_millis(50)) => {}
                never = report_bootstrap_progress(move || {
                    counted.fetch_add(1, Ordering::SeqCst);
                    50
                }) => match never {},
            }

            let ticked_while_bootstrapping = ticks.load(Ordering::SeqCst);
            assert!(ticked_while_bootstrapping > 0, "reporter never ran");
            tokio::time::sleep(BOOTSTRAP_PROGRESS_INTERVAL * 3).await;
            assert_eq!(
                ticks.load(Ordering::SeqCst),
                ticked_while_bootstrapping,
                "reporter outlived the bootstrap it was reporting on"
            );
        });
    }

    #[test]
    fn stale_generation_cannot_finish_current_attempt() {
        let active = AtomicU64::new(12);
        assert!(!finish_generation(&active, 11));
        assert_eq!(active.load(Ordering::SeqCst), 12);
        assert!(finish_generation(&active, 12));
        assert_eq!(active.load(Ordering::SeqCst), 0);
    }
}
