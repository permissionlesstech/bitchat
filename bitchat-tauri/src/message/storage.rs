//! Message Storage Module
//! 
//! Handles persistent storage of messages with efficient querying.

use anyhow::{Result, Context};
use log::{debug, warn};
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::message_types::BitchatMessage;

/// In-memory message storage (for this implementation)
/// In production, this would use a proper database like SQLite
pub struct MessageStorage {
    messages: Arc<RwLock<VecDeque<BitchatMessage>>>,
    max_messages: usize,
}

impl MessageStorage {
    pub fn new() -> Self {
        Self {
            messages: Arc::new(RwLock::new(VecDeque::new())),
            max_messages: 10000, // Limit to prevent memory issues
        }
    }
    
    /// Store a message
    pub async fn store_message(&self, message: &BitchatMessage) -> Result<()> {
        let mut messages = self.messages.write().await;
        
        // Check if message already exists
        if messages.iter().any(|m| m.id == message.id) {
            debug!("Message already stored: {}", message.id);
            return Ok(());
        }
        
        // Add message
        messages.push_back(message.clone());
        
        // Enforce size limit
        while messages.len() > self.max_messages {
            if let Some(removed) = messages.pop_front() {
                debug!("Removed old message due to size limit: {}", removed.id);
            }
        }
        
        debug!("Stored message: {} ({} chars)", message.id, message.content.len());
        Ok(())
    }
    
    /// Get messages for a channel or all messages if channel is None
    pub async fn get_messages(&self, channel: Option<&str>, limit: u32) -> Result<Vec<BitchatMessage>> {
        let messages = self.messages.read().await;
        
        let filtered: Vec<_> = messages.iter()
            .filter(|msg| {
                match channel {
                    Some(ch) => {
                        match &msg.channel {
                            Some(msg_channel) => msg_channel == ch,
                            None => ch == "public" || ch == "broadcast",
                        }
                    }
                    None => true, // All messages
                }
            })
            .rev() // Most recent first
            .take(limit as usize)
            .cloned()
            .collect();
        
        debug!("Retrieved {} messages for channel: {:?}", filtered.len(), channel);
        Ok(filtered)
    }
    
    /// Get message by ID
    pub async fn get_message(&self, message_id: &uuid::Uuid) -> Result<Option<BitchatMessage>> {
        let messages = self.messages.read().await;
        
        let message = messages.iter()
            .find(|msg| &msg.id == message_id)
            .cloned();
        
        Ok(message)
    }
    
    /// Get messages from a specific sender
    pub async fn get_messages_from_sender(&self, sender_id: [u8; 8], limit: u32) -> Result<Vec<BitchatMessage>> {
        let messages = self.messages.read().await;
        
        let filtered: Vec<_> = messages.iter()
            .filter(|msg| msg.sender_id == sender_id)
            .rev()
            .take(limit as usize)
            .cloned()
            .collect();
        
        debug!("Retrieved {} messages from sender: {:?}", filtered.len(), sender_id);
        Ok(filtered)
    }
    
    /// Get private messages between two peers
    pub async fn get_private_messages(
        &self,
        peer1: [u8; 8],
        peer2: [u8; 8],
        limit: u32,
    ) -> Result<Vec<BitchatMessage>> {
        let messages = self.messages.read().await;
        
        let filtered: Vec<_> = messages.iter()
            .filter(|msg| {
                matches!(msg.message_type, super::message_types::MessageType::Private) &&
                ((msg.sender_id == peer1 && msg.recipient_id == Some(peer2)) ||
                 (msg.sender_id == peer2 && msg.recipient_id == Some(peer1)))
            })
            .rev()
            .take(limit as usize)
            .cloned()
            .collect();
        
        debug!("Retrieved {} private messages between peers", filtered.len());
        Ok(filtered)
    }
    
    /// Search messages by content
    pub async fn search_messages(&self, query: &str, limit: u32) -> Result<Vec<BitchatMessage>> {
        let messages = self.messages.read().await;
        let query_lower = query.to_lowercase();
        
        let filtered: Vec<_> = messages.iter()
            .filter(|msg| {
                msg.content.to_lowercase().contains(&query_lower) ||
                msg.sender_nickname.to_lowercase().contains(&query_lower)
            })
            .rev()
            .take(limit as usize)
            .cloned()
            .collect();
        
        debug!("Found {} messages matching query: {}", filtered.len(), query);
        Ok(filtered)
    }
    
    /// Get messages with mentions of a specific user
    pub async fn get_mentions(&self, nickname: &str, limit: u32) -> Result<Vec<BitchatMessage>> {
        let messages = self.messages.read().await;
        
        let filtered: Vec<_> = messages.iter()
            .filter(|msg| msg.mentions_user(nickname))
            .rev()
            .take(limit as usize)
            .cloned()
            .collect();
        
        debug!("Retrieved {} messages mentioning: {}", filtered.len(), nickname);
        Ok(filtered)
    }
    
    /// Get unread messages
    pub async fn get_unread_messages(&self) -> Result<Vec<BitchatMessage>> {
        let messages = self.messages.read().await;
        
        let unread: Vec<_> = messages.iter()
            .filter(|msg| {
                matches!(msg.delivery_status, Some(super::message_types::DeliveryStatus::Delivered))
            })
            .cloned()
            .collect();
        
        debug!("Retrieved {} unread messages", unread.len());
        Ok(unread)
    }
    
    /// Update message status
    pub async fn update_message_status(
        &self,
        message_id: &uuid::Uuid,
        status: super::message_types::MessageStatus,
    ) -> Result<()> {
        let mut messages = self.messages.write().await;
        
        if let Some(message) = messages.iter_mut().find(|msg| &msg.id == message_id) {
            message.set_status(status);
            debug!("Updated message status: {} -> {:?}", message_id, message.status);
        } else {
            warn!("Message not found for status update: {}", message_id);
        }
        
        Ok(())
    }
    
    /// Update delivery status
    pub async fn update_delivery_status(
        &self,
        message_id: &uuid::Uuid,
        delivery_status: super::message_types::DeliveryStatus,
    ) -> Result<()> {
        let mut messages = self.messages.write().await;
        
        if let Some(message) = messages.iter_mut().find(|msg| &msg.id == message_id) {
            message.set_delivery_status(delivery_status);
            debug!("Updated delivery status: {} -> {:?}", message_id, message.delivery_status);
        } else {
            warn!("Message not found for delivery status update: {}", message_id);
        }
        
        Ok(())
    }
    
    /// Delete a message
    pub async fn delete_message(&self, message_id: &uuid::Uuid) -> Result<bool> {
        let mut messages = self.messages.write().await;
        
        if let Some(pos) = messages.iter().position(|msg| &msg.id == message_id) {
            messages.remove(pos);
            debug!("Deleted message: {}", message_id);
            Ok(true)
        } else {
            warn!("Message not found for deletion: {}", message_id);
            Ok(false)
        }
    }
    
    /// Delete messages older than specified age
    pub async fn delete_old_messages(&self, max_age_hours: u64) -> Result<usize> {
        let cutoff = chrono::Utc::now() - chrono::Duration::hours(max_age_hours as i64);
        let mut messages = self.messages.write().await;
        
        let original_len = messages.len();
        messages.retain(|msg| msg.timestamp >= cutoff);
        let deleted_count = original_len - messages.len();
        
        debug!("Deleted {} old messages (older than {} hours)", deleted_count, max_age_hours);
        Ok(deleted_count)
    }
    
    /// Clear all messages
    pub async fn clear_all_messages(&self) -> Result<usize> {
        let mut messages = self.messages.write().await;
        let count = messages.len();
        messages.clear();
        
        debug!("Cleared all {} messages", count);
        Ok(count)
    }
    
    /// Get storage statistics
    pub async fn get_statistics(&self) -> Value {
        let messages = self.messages.read().await;
        
        let total_messages = messages.len();
        let mut channel_counts = std::collections::HashMap::new();
        let mut type_counts = std::collections::HashMap::new();
        let mut status_counts = std::collections::HashMap::new();
        
        for message in messages.iter() {
            // Count by channel
            let channel_key = message.get_channel_display_name();
            *channel_counts.entry(channel_key).or_insert(0) += 1;
            
            // Count by type
            let type_key = format!("{:?}", message.message_type);
            *type_counts.entry(type_key).or_insert(0) += 1;
            
            // Count by status
            let status_key = format!("{:?}", message.status);
            *status_counts.entry(status_key).or_insert(0) += 1;
        }
        
        // Calculate storage usage (approximate)
        let estimated_size_bytes: usize = messages.iter()
            .map(|msg| {
                msg.content.len() + 
                msg.sender_nickname.len() + 
                msg.channel.as_ref().map_or(0, |c| c.len()) +
                200 // Approximate overhead per message
            })
            .sum();
        
        serde_json::json!({
            "total_messages": total_messages,
            "max_messages": self.max_messages,
            "estimated_size_bytes": estimated_size_bytes,
            "estimated_size_mb": estimated_size_bytes as f64 / 1_048_576.0,
            "by_channel": channel_counts,
            "by_type": type_counts,
            "by_status": status_counts
        })
    }
    
    /// Export messages to JSON
    pub async fn export_messages(&self, channel: Option<&str>) -> Result<String> {
        let messages = self.get_messages(channel, u32::MAX).await?;
        
        let export_data = serde_json::json!({
            "export_timestamp": chrono::Utc::now(),
            "channel": channel,
            "message_count": messages.len(),
            "messages": messages
        });
        
        serde_json::to_string_pretty(&export_data)
            .context("Failed to serialize messages for export")
    }
    
    /// Import messages from JSON
    pub async fn import_messages(&self, json_data: &str) -> Result<usize> {
        let import_data: Value = serde_json::from_str(json_data)
            .context("Failed to parse import data")?;
        
        let messages_array = import_data["messages"].as_array()
            .context("Invalid import format: missing messages array")?;
        
        let mut imported_count = 0;
        
        for message_value in messages_array {
            if let Ok(message) = serde_json::from_value::<BitchatMessage>(message_value.clone()) {
                self.store_message(&message).await?;
                imported_count += 1;
            } else {
                warn!("Failed to parse message during import");
            }
        }
        
        debug!("Imported {} messages", imported_count);
        Ok(imported_count)
    }
}

impl Default for MessageStorage {
    fn default() -> Self {
        Self::new()
    }
}