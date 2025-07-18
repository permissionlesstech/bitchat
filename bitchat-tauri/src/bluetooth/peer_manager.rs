//! Peer Management Module
//! 
//! Manages discovered peers, connection states, and peer metadata
//! following the AI Guidance Protocol for ethical peer-to-peer networking.

use anyhow::Result;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};
use tokio::sync::RwLock;

/// Maximum number of concurrent peer connections
const MAX_PEER_CONNECTIONS: usize = 8;

/// Peer announcement interval in seconds
const PEER_ANNOUNCE_INTERVAL: u64 = 30;

/// Peer timeout in seconds (when to consider a peer offline)
const PEER_TIMEOUT: u64 = 90;

/// Connection state for a peer
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConnectionState {
    Discovering,    // Found in advertisement, not connected
    Connecting,     // Connection attempt in progress
    Connected,      // Active BLE connection established
    Authenticated,  // Noise handshake completed
    Disconnected,   // Previously connected, now offline
    Failed,         // Connection failed
}

/// Information about a discovered peer
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerInfo {
    pub peer_id: [u8; 8],
    pub nickname: String,
    pub connection_state: ConnectionState,
    pub last_seen: SystemTime,
    pub first_seen: SystemTime,
    pub rssi: Option<i16>,
    pub device_address: Option<String>,
    pub noise_public_key: Option<[u8; 32]>,
    pub fingerprint: Option<String>,
    pub message_count: u64,
    pub is_favorite: bool,
    pub is_blocked: bool,
    pub channels: Vec<String>,
}

impl PeerInfo {
    pub fn new(peer_id: [u8; 8], nickname: String) -> Self {
        let now = SystemTime::now();
        
        Self {
            peer_id,
            nickname,
            connection_state: ConnectionState::Discovering,
            last_seen: now,
            first_seen: now,
            rssi: None,
            device_address: None,
            noise_public_key: None,
            fingerprint: None,
            message_count: 0,
            is_favorite: false,
            is_blocked: false,
            channels: Vec::new(),
        }
    }
    
    /// Update peer's last seen timestamp
    pub fn update_last_seen(&mut self) {
        self.last_seen = SystemTime::now();
    }
    
    /// Check if peer is considered online
    pub fn is_online(&self) -> bool {
        match self.connection_state {
            ConnectionState::Connected | ConnectionState::Authenticated => true,
            _ => {
                // Check if we've seen them recently even if not actively connected
                if let Ok(elapsed) = self.last_seen.elapsed() {
                    elapsed.as_secs() < PEER_TIMEOUT
                } else {
                    false
                }
            }
        }
    }
    
    /// Get connection quality based on RSSI and connection state
    pub fn get_connection_quality(&self) -> f32 {
        match self.connection_state {
            ConnectionState::Authenticated => {
                if let Some(rssi) = self.rssi {
                    // Convert RSSI to quality score (0.0 to 1.0)
                    // Typical BLE RSSI range: -100 to -30 dBm
                    let quality = ((rssi + 100) as f32 / 70.0).clamp(0.0, 1.0);
                    quality
                } else {
                    0.8 // Default good quality if no RSSI data
                }
            }
            ConnectionState::Connected => 0.6,
            ConnectionState::Connecting => 0.3,
            _ => 0.0,
        }
    }
}

/// Manages all discovered peers and their connections
pub struct PeerManager {
    peers: Arc<DashMap<[u8; 8], PeerInfo>>,
    own_peer_id: Arc<RwLock<[u8; 8]>>,
    own_nickname: Arc<RwLock<String>>,
    last_announce: Arc<RwLock<Instant>>,
    favorites: Arc<DashMap<[u8; 8], bool>>,
    blocked_peers: Arc<DashMap<[u8; 8], bool>>,
}

impl PeerManager {
    pub fn new() -> Self {
        Self {
            peers: Arc::new(DashMap::new()),
            own_peer_id: Arc::new(RwLock::new([0u8; 8])),
            own_nickname: Arc::new(RwLock::new("Anonymous".to_string())),
            last_announce: Arc::new(RwLock::new(Instant::now() - Duration::from_secs(PEER_ANNOUNCE_INTERVAL))),
            favorites: Arc::new(DashMap::new()),
            blocked_peers: Arc::new(DashMap::new()),
        }
    }
    
    /// Initialize peer manager with own identity
    pub async fn initialize(&self, peer_id: [u8; 8], nickname: String) -> Result<()> {
        *self.own_peer_id.write().await = peer_id;
        *self.own_nickname.write().await = nickname;
        
        log::info!("Peer manager initialized with ID: {:?}", peer_id);
        Ok(())
    }
    
    /// Get our own peer ID
    pub async fn get_own_peer_id(&self) -> [u8; 8] {
        *self.own_peer_id.read().await
    }
    
    /// Get our own nickname
    pub async fn get_own_nickname(&self) -> String {
        self.own_nickname.read().await.clone()
    }
    
    /// Set our nickname
    pub async fn set_nickname(&self, nickname: String) -> Result<()> {
        *self.own_nickname.write().await = nickname;
        log::info!("Nickname updated");
        Ok(())
    }
    
    /// Add or update a discovered peer
    pub async fn add_or_update_peer(&self, peer_id: [u8; 8], nickname: String) -> Result<()> {
        // Don't add ourselves
        let own_id = self.get_own_peer_id().await;
        if peer_id == own_id {
            return Ok(());
        }
        
        // Check if peer is blocked
        if self.blocked_peers.contains_key(&peer_id) {
            log::debug!("Ignoring blocked peer: {:?}", peer_id);
            return Ok(());
        }
        
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            // Update existing peer
            peer_info.nickname = nickname;
            peer_info.update_last_seen();
            log::debug!("Updated peer: {} ({:?})", peer_info.nickname, peer_id);
        } else {
            // Add new peer
            let peer_info = PeerInfo::new(peer_id, nickname.clone());
            self.peers.insert(peer_id, peer_info);
            log::info!("Discovered new peer: {} ({:?})", nickname, peer_id);
        }
        
        Ok(())
    }
    
    /// Update peer connection state
    pub async fn update_peer_connection_state(&self, peer_id: [u8; 8], state: ConnectionState) -> Result<()> {
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.connection_state = state.clone();
            peer_info.update_last_seen();
            
            log::debug!("Peer {} connection state: {:?}", peer_info.nickname, state);
        }
        
        Ok(())
    }
    
    /// Update peer RSSI
    pub async fn update_peer_rssi(&self, peer_id: [u8; 8], rssi: i16) -> Result<()> {
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.rssi = Some(rssi);
            peer_info.update_last_seen();
        }
        
        Ok(())
    }
    
    /// Set peer's Noise public key and fingerprint
    pub async fn set_peer_crypto_info(&self, peer_id: [u8; 8], public_key: [u8; 32], fingerprint: String) -> Result<()> {
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.noise_public_key = Some(public_key);
            peer_info.fingerprint = Some(fingerprint);
        }
        
        Ok(())
    }
    
    /// Get list of all peers
    pub async fn get_all_peers(&self) -> Vec<PeerInfo> {
        self.peers.iter().map(|entry| entry.value().clone()).collect()
    }
    
    /// Get list of online peers
    pub async fn get_online_peers(&self) -> Vec<PeerInfo> {
        self.peers
            .iter()
            .filter(|entry| entry.value().is_online())
            .map(|entry| entry.value().clone())
            .collect()
    }
    
    /// Get list of connected peers (for message routing)
    pub async fn get_connected_peers(&self) -> Vec<PeerInfo> {
        self.peers
            .iter()
            .filter(|entry| {
                matches!(
                    entry.value().connection_state,
                    ConnectionState::Connected | ConnectionState::Authenticated
                )
            })
            .map(|entry| entry.value().clone())
            .collect()
    }
    
    /// Get peer info by ID
    pub async fn get_peer(&self, peer_id: [u8; 8]) -> Option<PeerInfo> {
        self.peers.get(&peer_id).map(|entry| entry.value().clone())
    }
    
    /// Get peer info by nickname
    pub async fn get_peer_by_nickname(&self, nickname: &str) -> Option<PeerInfo> {
        self.peers
            .iter()
            .find(|entry| entry.value().nickname == nickname)
            .map(|entry| entry.value().clone())
    }
    
    /// Add peer to favorites
    pub async fn add_favorite(&self, peer_id: [u8; 8]) -> Result<()> {
        self.favorites.insert(peer_id, true);
        
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.is_favorite = true;
        }
        
        log::info!("Added peer to favorites: {:?}", peer_id);
        Ok(())
    }
    
    /// Remove peer from favorites
    pub async fn remove_favorite(&self, peer_id: [u8; 8]) -> Result<()> {
        self.favorites.remove(&peer_id);
        
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.is_favorite = false;
        }
        
        log::info!("Removed peer from favorites: {:?}", peer_id);
        Ok(())
    }
    
    /// Block a peer
    pub async fn block_peer(&self, peer_id: [u8; 8]) -> Result<()> {
        self.blocked_peers.insert(peer_id, true);
        
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.is_blocked = true;
            peer_info.connection_state = ConnectionState::Disconnected;
        }
        
        log::info!("Blocked peer: {:?}", peer_id);
        Ok(())
    }
    
    /// Unblock a peer
    pub async fn unblock_peer(&self, peer_id: [u8; 8]) -> Result<()> {
        self.blocked_peers.remove(&peer_id);
        
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.is_blocked = false;
        }
        
        log::info!("Unblocked peer: {:?}", peer_id);
        Ok(())
    }
    
    /// Check if we should announce our presence
    pub async fn should_announce(&self) -> bool {
        let last_announce = *self.last_announce.read().await;
        last_announce.elapsed().as_secs() >= PEER_ANNOUNCE_INTERVAL
    }
    
    /// Mark that we just announced
    pub async fn mark_announced(&self) {
        *self.last_announce.write().await = Instant::now();
    }
    
    /// Clean up offline peers
    pub async fn cleanup_offline_peers(&self) -> Result<()> {
        let timeout_duration = Duration::from_secs(PEER_TIMEOUT);
        let mut to_remove = Vec::new();
        
        for entry in self.peers.iter() {
            let peer_info = entry.value();
            
            // Don't remove favorites, just mark them as offline
            if peer_info.is_favorite {
                continue;
            }
            
            if let Ok(elapsed) = peer_info.last_seen.elapsed() {
                if elapsed > timeout_duration && !peer_info.is_online() {
                    to_remove.push(*entry.key());
                }
            }
        }
        
        for peer_id in to_remove {
            self.peers.remove(&peer_id);
            log::debug!("Removed offline peer: {:?}", peer_id);
        }
        
        Ok(())
    }
    
    /// Get peer statistics
    pub async fn get_statistics(&self) -> serde_json::Value {
        let total_peers = self.peers.len();
        let online_peers = self.get_online_peers().await.len();
        let connected_peers = self.get_connected_peers().await.len();
        let favorites_count = self.favorites.len();
        let blocked_count = self.blocked_peers.len();
        
        serde_json::json!({
            "total_peers": total_peers,
            "online_peers": online_peers,
            "connected_peers": connected_peers,
            "favorites": favorites_count,
            "blocked": blocked_count,
            "own_peer_id": format!("{:?}", self.get_own_peer_id().await),
            "own_nickname": self.get_own_nickname().await
        })
    }
    
    /// Increment message count for a peer
    pub async fn increment_message_count(&self, peer_id: [u8; 8]) -> Result<()> {
        if let Some(mut peer_info) = self.peers.get_mut(&peer_id) {
            peer_info.message_count += 1;
        }
        Ok(())
    }
    
    /// Get best peers for message routing (by connection quality)
    pub async fn get_routing_peers(&self, max_count: usize) -> Vec<PeerInfo> {
        let mut connected_peers = self.get_connected_peers().await;
        
        // Sort by connection quality (best first)
        connected_peers.sort_by(|a, b| {
            b.get_connection_quality()
                .partial_cmp(&a.get_connection_quality())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        
        connected_peers.into_iter().take(max_count).collect()
    }
}

impl Default for PeerManager {
    fn default() -> Self {
        Self::new()
    }
}