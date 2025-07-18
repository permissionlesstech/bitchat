//! Message Router
//! 
//! Handles message routing, delivery, and mesh network propagation.

use anyhow::Result;
use log::{info, debug};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::message_types::{BitchatMessage, MessageType};
use super::storage::MessageStorage;

/// Message router for handling mesh network message propagation
pub struct MessageRouter {
    storage: MessageStorage,
    active_channels: Arc<RwLock<HashMap<String, ChannelInfo>>>,
    message_cache: Arc<RwLock<HashMap<uuid::Uuid, BitchatMessage>>>,
    routing_table: Arc<RwLock<HashMap<[u8; 8], Vec<[u8; 8]>>>>, // peer_id -> route via peers
}

/// Information about a joined channel
#[derive(Debug, Clone)]
struct ChannelInfo {
    name: String,
    joined_at: chrono::DateTime<chrono::Utc>,
    has_password: bool,
    member_count: usize,
    last_activity: chrono::DateTime<chrono::Utc>,
}

impl MessageRouter {
    pub fn new() -> Self {
        Self {
            storage: MessageStorage::new(),
            active_channels: Arc::new(RwLock::new(HashMap::new())),
            message_cache: Arc::new(RwLock::new(HashMap::new())),
            routing_table: Arc::new(RwLock::new(HashMap::new())),
        }
    }
    
    /// Send a broadcast message
    pub async fn send_message(&self, content: String, channel: Option<String>) -> Result<String> {
        info!("Sending message: {} chars to channel: {:?}", content.len(), channel);
        
        // Create message based on channel
        let message = if let Some(channel_name) = channel {
            // Channel message
            let sender_id = [0u8; 8]; // TODO: Get actual sender ID
            let sender_nickname = "User".to_string(); // TODO: Get actual nickname
            
            BitchatMessage::new_channel(sender_id, sender_nickname, channel_name, content)
        } else {
            // Broadcast message
            let sender_id = [0u8; 8]; // TODO: Get actual sender ID
            let sender_nickname = "User".to_string(); // TODO: Get actual nickname
            
            BitchatMessage::new_broadcast(sender_id, sender_nickname, content)
        };
        
        // Store message
        self.storage.store_message(&message).await?;
        
        // Cache message for routing
        self.message_cache.write().await.insert(message.id, message.clone());
        
        // TODO: Send via Bluetooth mesh service
        debug!("Message queued for transmission: {}", message.id);
        
        Ok(message.id.to_string())
    }
    
    /// Send a private message to a specific peer
    pub async fn send_private_message(&self, recipient: String, content: String) -> Result<String> {
        info!("Sending private message to: {}", recipient);
        
        // TODO: Look up recipient peer ID from nickname
        let recipient_id = [0u8; 8]; // Placeholder
        let sender_id = [0u8; 8]; // TODO: Get actual sender ID
        let sender_nickname = "User".to_string(); // TODO: Get actual nickname
        
        let message = BitchatMessage::new_private(
            sender_id,
            sender_nickname,
            recipient_id,
            recipient.clone(),
            content,
        );
        
        // Store message
        self.storage.store_message(&message).await?;
        
        // Cache message for routing
        self.message_cache.write().await.insert(message.id, message.clone());
        
        // TODO: Send via Bluetooth mesh service with encryption
        debug!("Private message queued for transmission: {}", message.id);
        
        Ok(message.id.to_string())
    }
    
    /// Join a channel
    pub async fn join_channel(&self, channel_name: String, password: Option<String>) -> Result<String> {
        info!("Joining channel: {}", channel_name);
        
        let channel_info = ChannelInfo {
            name: channel_name.clone(),
            joined_at: chrono::Utc::now(),
            has_password: password.is_some(),
            member_count: 1, // Just us for now
            last_activity: chrono::Utc::now(),
        };
        
        self.active_channels.write().await.insert(channel_name.clone(), channel_info);
        
        // Create system message about joining
        let system_message = BitchatMessage::new_system(format!("Joined channel: {}", channel_name));
        self.storage.store_message(&system_message).await?;
        
        // TODO: Announce channel join to mesh network
        
        Ok(format!("Joined channel: {}", channel_name))
    }
    
    /// Leave a channel
    pub async fn leave_channel(&self, channel_name: String) -> Result<String> {
        info!("Leaving channel: {}", channel_name);
        
        self.active_channels.write().await.remove(&channel_name);
        
        // Create system message about leaving
        let system_message = BitchatMessage::new_system(format!("Left channel: {}", channel_name));
        self.storage.store_message(&system_message).await?;
        
        // TODO: Announce channel leave to mesh network
        
        Ok(format!("Left channel: {}", channel_name))
    }
    
    /// Get message history for a channel or private conversation
    pub async fn get_message_history(&self, channel: Option<String>, limit: Option<u32>) -> Result<Value> {
        debug!("Getting message history for channel: {:?}, limit: {:?}", channel, limit);
        
        let messages = self.storage.get_messages(channel.as_deref(), limit.unwrap_or(50)).await?;
        
        let message_data: Vec<_> = messages.iter()
            .map(|msg| serde_json::json!({
                "id": msg.id,
                "sender": msg.get_sender_display_name(),
                "content": msg.content,
                "timestamp": msg.timestamp,
                "channel": msg.get_channel_display_name(),
                "type": msg.message_type,
                "status": msg.status,
                "mentions": msg.mentions,
                "is_encrypted": msg.is_encrypted
            }))
            .collect();
        
        Ok(serde_json::json!({
            "messages": message_data,
            "total": messages.len(),
            "channel": channel
        }))
    }
    
    /// Process incoming message from mesh network
    pub async fn process_incoming_message(&self, message: BitchatMessage) -> Result<()> {
        debug!("Processing incoming message: {}", message.id);
        
        // Check if we've already seen this message
        if self.message_cache.read().await.contains_key(&message.id) {
            debug!("Message already processed: {}", message.id);
            return Ok(());
        }
        
        // Store message
        self.storage.store_message(&message).await?;
        
        // Cache message
        self.message_cache.write().await.insert(message.id, message.clone());
        
        // Handle different message types
        match message.message_type {
            MessageType::Private => {
                self.handle_private_message(&message).await?;
            }
            MessageType::Channel => {
                self.handle_channel_message(&message).await?;
            }
            MessageType::Broadcast => {
                self.handle_broadcast_message(&message).await?;
            }
            MessageType::System => {
                self.handle_system_message(&message).await?;
            }
            MessageType::Announcement => {
                self.handle_announcement(&message).await?;
            }
            MessageType::DeliveryReceipt => {
                self.handle_delivery_receipt(&message).await?;
            }
        }
        
        // Consider relaying message if appropriate
        if message.should_relay() {
            self.consider_relay(&message).await?;
        }
        
        Ok(())
    }
    
    /// Handle private message
    async fn handle_private_message(&self, message: &BitchatMessage) -> Result<()> {
        debug!("Handling private message from {}", message.get_sender_display_name());
        
        // TODO: Check if message is for us
        // TODO: Decrypt if encrypted
        // TODO: Send delivery receipt
        
        Ok(())
    }
    
    /// Handle channel message
    async fn handle_channel_message(&self, message: &BitchatMessage) -> Result<()> {
        if let Some(channel_name) = &message.channel {
            debug!("Handling channel message in: {}", channel_name);
            
            // Update channel activity
            if let Some(channel_info) = self.active_channels.write().await.get_mut(channel_name) {
                channel_info.last_activity = chrono::Utc::now();
            }
            
            // TODO: Decrypt with channel key if encrypted
            // TODO: Process mentions
        }
        
        Ok(())
    }
    
    /// Handle broadcast message
    async fn handle_broadcast_message(&self, message: &BitchatMessage) -> Result<()> {
        debug!("Handling broadcast message from {}", message.get_sender_display_name());
        
        // TODO: Process mentions
        // TODO: Check for commands
        
        Ok(())
    }
    
    /// Handle system message
    async fn handle_system_message(&self, message: &BitchatMessage) -> Result<()> {
        debug!("Handling system message: {}", message.content);
        
        // System messages are typically local and don't need special processing
        Ok(())
    }
    
    /// Handle peer announcement
    async fn handle_announcement(&self, message: &BitchatMessage) -> Result<()> {
        debug!("Handling announcement from {}", message.get_sender_display_name());
        
        // TODO: Update peer information
        // TODO: Update routing table
        
        Ok(())
    }
    
    /// Handle delivery receipt
    async fn handle_delivery_receipt(&self, _message: &BitchatMessage) -> Result<()> {
        debug!("Handling delivery receipt");
        
        // TODO: Parse receipt and update original message status
        
        Ok(())
    }
    
    /// Consider relaying a message to other peers
    async fn consider_relay(&self, message: &BitchatMessage) -> Result<()> {
        debug!("Considering relay for message: {}", message.id);
        
        // TODO: Implement probabilistic relay based on:
        // - Message TTL
        // - Network density
        // - Message importance
        // - Battery level
        
        Ok(())
    }
    
    /// Update routing table with peer information
    pub async fn update_routing_table(&self, peer_id: [u8; 8], route_via: Vec<[u8; 8]>) -> Result<()> {
        self.routing_table.write().await.insert(peer_id, route_via);
        Ok(())
    }
    
    /// Get best route to a peer
    pub async fn get_route_to_peer(&self, peer_id: [u8; 8]) -> Option<Vec<[u8; 8]>> {
        self.routing_table.read().await.get(&peer_id).cloned()
    }
    
    /// Get list of active channels
    pub async fn get_active_channels(&self) -> Vec<String> {
        self.active_channels.read().await.keys().cloned().collect()
    }
    
    /// Get channel information
    pub async fn get_channel_info(&self, channel_name: &str) -> Option<Value> {
        if let Some(channel_info) = self.active_channels.read().await.get(channel_name) {
            Some(serde_json::json!({
                "name": channel_info.name,
                "joined_at": channel_info.joined_at,
                "has_password": channel_info.has_password,
                "member_count": channel_info.member_count,
                "last_activity": channel_info.last_activity
            }))
        } else {
            None
        }
    }
    
    /// Get router statistics
    pub async fn get_statistics(&self) -> Value {
        let cached_messages = self.message_cache.read().await.len();
        let routing_entries = self.routing_table.read().await.len();
        let active_channels = self.active_channels.read().await.len();
        
        serde_json::json!({
            "cached_messages": cached_messages,
            "routing_entries": routing_entries,
            "active_channels": active_channels,
            "storage_stats": self.storage.get_statistics().await
        })
    }
    
    /// Clean up old cached messages
    pub async fn cleanup_cache(&self, max_age_hours: u64) -> Result<usize> {
        let cutoff = chrono::Utc::now() - chrono::Duration::hours(max_age_hours as i64);
        let mut removed_count = 0;
        
        let mut cache = self.message_cache.write().await;
        let mut to_remove = Vec::new();
        
        for (id, message) in cache.iter() {
            if message.timestamp < cutoff {
                to_remove.push(*id);
            }
        }
        
        for id in to_remove {
            cache.remove(&id);
            removed_count += 1;
        }
        
        debug!("Cleaned up {} old messages from cache", removed_count);
        Ok(removed_count)
    }
}

impl Default for MessageRouter {
    fn default() -> Self {
        Self::new()
    }
}