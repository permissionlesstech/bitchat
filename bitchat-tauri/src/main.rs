#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! BitChat Tauri - Decentralized Bluetooth LE Mesh Messaging
//! 
//! A Rust + Tauri implementation of BitChat, providing decentralized
//! peer-to-peer messaging over Bluetooth LE mesh networks.
//! 
//! Follows AI Guidance Protocol for ethical, secure development.

use anyhow::Result;
use log::{info, error};
use tauri::{Manager, State};
use serde_json::Value;

mod bluetooth;
mod crypto;
mod message;
mod ui_state;

use bluetooth::BluetoothMeshService;
use crypto::CryptoEngine;
use message::MessageRouter;
use ui_state::BitchatState;

/// Application state for BitChat Tauri
#[derive(Default)]
pub struct AppState {
    pub bluetooth_service: BluetoothMeshService,
    pub crypto_engine: CryptoEngine,
    pub message_router: MessageRouter,
    pub ui_state: BitchatState,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            bluetooth_service: BluetoothMeshService::new(),
            crypto_engine: CryptoEngine::new(),
            message_router: MessageRouter::new(),
            ui_state: BitchatState::new(),
        }
    }
}

fn main() {
    env_logger::init();
    
    info!("=== BitChat Tauri: Decentralized Mesh Messaging ===");
    info!("Bluetooth LE mesh networking with end-to-end encryption");
    
    let app_state = AppState::new();
    
    tauri::Builder::default()
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![
            // Bluetooth mesh networking
            start_bluetooth_service,
            stop_bluetooth_service,
            get_bluetooth_status,
            get_peer_list,
            
            // Messaging
            send_message,
            send_private_message,
            join_channel,
            leave_channel,
            get_message_history,
            
            // Cryptography
            get_fingerprint,
            verify_peer_fingerprint,
            set_channel_password,
            
            // UI state
            get_app_state,
            update_preferences,
            get_statistics,
        ])
        .setup(|app| {
            let window = app.get_webview_window("main").unwrap();
            window.set_title("BitChat - Decentralized Mesh Messaging")?;
            
            info!("[BitChat] Tauri application initialized");
            info!("[BitChat] Bluetooth LE mesh service ready");
            info!("[BitChat] End-to-end encryption enabled");
            
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running BitChat Tauri application");
}

// Bluetooth mesh networking commands
#[tauri::command]
async fn start_bluetooth_service(
    state: State<'_, AppState>,
) -> Result<String, String> {
    info!("Starting Bluetooth LE mesh service");
    
    match state.bluetooth_service.start().await {
        Ok(_) => {
            info!("Bluetooth LE mesh service started successfully");
            Ok("Bluetooth service started".to_string())
        }
        Err(e) => {
            error!("Failed to start Bluetooth service: {}", e);
            Err(e.to_string())
        }
    }
}

#[tauri::command]
async fn stop_bluetooth_service(
    state: State<'_, AppState>,
) -> Result<String, String> {
    info!("Stopping Bluetooth LE mesh service");
    
    match state.bluetooth_service.stop().await {
        Ok(_) => {
            info!("Bluetooth LE mesh service stopped successfully");
            Ok("Bluetooth service stopped".to_string())
        }
        Err(e) => {
            error!("Failed to stop Bluetooth service: {}", e);
            Err(e.to_string())
        }
    }
}

#[tauri::command]
async fn get_bluetooth_status(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    state.bluetooth_service.get_status().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_peer_list(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    state.bluetooth_service.get_peer_list().await
        .map_err(|e| e.to_string())
}

// Messaging commands
#[tauri::command]
async fn send_message(
    content: String,
    channel: Option<String>,
    state: State<'_, AppState>,
) -> Result<String, String> {
    info!("Sending message: {} chars", content.len());
    
    state.message_router.send_message(content, channel).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn send_private_message(
    recipient: String,
    content: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    info!("Sending private message to: {}", recipient);
    
    state.message_router.send_private_message(recipient, content).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn join_channel(
    channel_name: String,
    password: Option<String>,
    state: State<'_, AppState>,
) -> Result<String, String> {
    info!("Joining channel: {}", channel_name);
    
    state.message_router.join_channel(channel_name, password).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn leave_channel(
    channel_name: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    info!("Leaving channel: {}", channel_name);
    
    state.message_router.leave_channel(channel_name).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_message_history(
    channel: Option<String>,
    limit: Option<u32>,
    state: State<'_, AppState>,
) -> Result<Value, String> {
    state.message_router.get_message_history(channel, limit).await
        .map_err(|e| e.to_string())
}

// Cryptography commands
#[tauri::command]
async fn get_fingerprint(
    state: State<'_, AppState>,
) -> Result<String, String> {
    state.crypto_engine.get_fingerprint().await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn verify_peer_fingerprint(
    peer_id: String,
    expected_fingerprint: String,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    state.crypto_engine.verify_peer_fingerprint(peer_id, expected_fingerprint).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn set_channel_password(
    channel: String,
    password: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    state.crypto_engine.set_channel_password(channel, password).await
        .map_err(|e| e.to_string())
}

// UI state commands
#[tauri::command]
async fn get_app_state(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    Ok(state.ui_state.get_current_state().await)
}

#[tauri::command]
async fn update_preferences(
    preferences: Value,
    state: State<'_, AppState>,
) -> Result<String, String> {
    state.ui_state.update_preferences(preferences).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_statistics(
    state: State<'_, AppState>,
) -> Result<Value, String> {
    state.bluetooth_service.get_statistics().await
        .map_err(|e| e.to_string())
}