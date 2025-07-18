//! Message Type Definitions
//! 
//! Defines the core message structures used throughout BitChat.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Status of a message in the system
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MessageStatus {
    Draft,      // Message being composed
    Sending,    // Message being transmitted
    Sent,       // Message transmitted successfully
    Delivered,  // Message delivered to recipient
    Failed,     // Message transmission failed
    Expired,    // Message TTL expired
}

/// Delivery status for tracking message delivery
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeliveryStatus {
    Pending,    // Awaiting delivery
    Delivered,  // Successfully delivered
    Read,       // Message has been read
    Failed,     // Delivery failed
}

/// Core BitChat message structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BitchatMessage {
    pub id: Uuid,
    pub sender_id: [u8; 8],
    pub sender_nickname: String,
    pub content: String,
    pub timestamp: DateTime<Utc>,
    pub message_type: MessageType,
    pub channel: Option<String>,
    pub recipient_id: Option<[u8; 8]>,
    pub recipient_nickname: Option<String>,
    pub is_encrypted: bool,
    pub is_compressed: bool,
    pub ttl: u8,
    pub hop_count: u8,
    pub status: MessageStatus,
    pub delivery_status: Option<DeliveryStatus>,
    pub mentions: Vec<String>,
    pub reply_to: Option<Uuid>,
    pub forwarded_from: Option<[u8; 8]>,
    pub signature: Option<Vec<u8>>,
    pub metadata: serde_json::Value,
}

/// Type of message being sent
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MessageType {
    Broadcast,      // Public message to all peers
    Private,        // Direct message to specific peer
    Channel,        // Message in a specific channel
    System,         // System notification
    Announcement,   // Peer announcement
    DeliveryReceipt, // Delivery confirmation
}

impl BitchatMessage {
    /// Create a new broadcast message
    pub fn new_broadcast(
        sender_id: [u8; 8],
        sender_nickname: String,
        content: String,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            sender_id,
            sender_nickname,
            content,
            timestamp: Utc::now(),
            message_type: MessageType::Broadcast,
            channel: None,
            recipient_id: None,
            recipient_nickname: None,
            is_encrypted: false,
            is_compressed: false,
            ttl: 7,
            hop_count: 0,
            status: MessageStatus::Draft,
            delivery_status: None,
            mentions: Vec::new(),
            reply_to: None,
            forwarded_from: None,
            signature: None,
            metadata: serde_json::Value::Object(serde_json::Map::new()),
        }
    }
    
    /// Create a new private message
    pub fn new_private(
        sender_id: [u8; 8],
        sender_nickname: String,
        recipient_id: [u8; 8],
        recipient_nickname: String,
        content: String,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            sender_id,
            sender_nickname,
            content,
            timestamp: Utc::now(),
            message_type: MessageType::Private,
            channel: None,
            recipient_id: Some(recipient_id),
            recipient_nickname: Some(recipient_nickname),
            is_encrypted: true, // Private messages are always encrypted
            is_compressed: false,
            ttl: 7,
            hop_count: 0,
            status: MessageStatus::Draft,
            delivery_status: Some(DeliveryStatus::Pending),
            mentions: Vec::new(),
            reply_to: None,
            forwarded_from: None,
            signature: None,
            metadata: serde_json::Value::Object(serde_json::Map::new()),
        }
    }
    
    /// Create a new channel message
    pub fn new_channel(
        sender_id: [u8; 8],
        sender_nickname: String,
        channel: String,
        content: String,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            sender_id,
            sender_nickname,
            content,
            timestamp: Utc::now(),
            message_type: MessageType::Channel,
            channel: Some(channel),
            recipient_id: None,
            recipient_nickname: None,
            is_encrypted: true, // Channel messages are encrypted with channel key
            is_compressed: false,
            ttl: 7,
            hop_count: 0,
            status: MessageStatus::Draft,
            delivery_status: None,
            mentions: Vec::new(),
            reply_to: None,
            forwarded_from: None,
            signature: None,
            metadata: serde_json::Value::Object(serde_json::Map::new()),
        }
    }
    
    /// Create a system message
    pub fn new_system(content: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            sender_id: [0u8; 8], // System messages have no sender
            sender_nickname: "System".to_string(),
            content,
            timestamp: Utc::now(),
            message_type: MessageType::System,
            channel: None,
            recipient_id: None,
            recipient_nickname: None,
            is_encrypted: false,
            is_compressed: false,
            ttl: 1, // System messages don't propagate
            hop_count: 0,
            status: MessageStatus::Sent,
            delivery_status: None,
            mentions: Vec::new(),
            reply_to: None,
            forwarded_from: None,
            signature: None,
            metadata: serde_json::Value::Object(serde_json::Map::new()),
        }
    }
    
    /// Add a mention to the message
    pub fn add_mention(&mut self, nickname: String) {
        if !self.mentions.contains(&nickname) {
            self.mentions.push(nickname);
        }
    }
    
    /// Set as reply to another message
    pub fn set_reply_to(&mut self, message_id: Uuid) {
        self.reply_to = Some(message_id);
    }
    
    /// Mark as forwarded from another peer
    pub fn set_forwarded_from(&mut self, original_sender: [u8; 8]) {
        self.forwarded_from = Some(original_sender);
    }
    
    /// Update message status
    pub fn set_status(&mut self, status: MessageStatus) {
        self.status = status;
    }
    
    /// Update delivery status
    pub fn set_delivery_status(&mut self, delivery_status: DeliveryStatus) {
        self.delivery_status = Some(delivery_status);
    }
    
    /// Decrease TTL for message forwarding
    pub fn decrease_ttl(&mut self) -> bool {
        if self.ttl > 0 {
            self.ttl -= 1;
            self.hop_count += 1;
            true
        } else {
            false
        }
    }
    
    /// Check if message is expired
    pub fn is_expired(&self) -> bool {
        self.ttl == 0 || matches!(self.status, MessageStatus::Expired)
    }
    
    /// Check if message should be relayed
    pub fn should_relay(&self) -> bool {
        self.ttl > 0 && 
        !matches!(self.message_type, MessageType::System | MessageType::DeliveryReceipt) &&
        !matches!(self.status, MessageStatus::Failed | MessageStatus::Expired)
    }
    
    /// Get display name for sender
    pub fn get_sender_display_name(&self) -> &str {
        if self.sender_nickname.is_empty() {
            "Anonymous"
        } else {
            &self.sender_nickname
        }
    }
    
    /// Get channel display name
    pub fn get_channel_display_name(&self) -> String {
        match &self.channel {
            Some(channel) => channel.clone(),
            None => match self.message_type {
                MessageType::Private => "Private".to_string(),
                MessageType::System => "System".to_string(),
                _ => "Public".to_string(),
            }
        }
    }
    
    /// Check if message contains a mention of the given nickname
    pub fn mentions_user(&self, nickname: &str) -> bool {
        self.mentions.iter().any(|mention| mention == nickname) ||
        self.content.contains(&format!("@{}", nickname))
    }
    
    /// Get formatted timestamp
    pub fn get_formatted_timestamp(&self) -> String {
        self.timestamp.format("%H:%M:%S").to_string()
    }
    
    /// Get age of message in seconds
    pub fn get_age_seconds(&self) -> i64 {
        (Utc::now() - self.timestamp).num_seconds()
    }
    
    /// Check if message is recent (less than 1 hour old)
    pub fn is_recent(&self) -> bool {
        self.get_age_seconds() < 3600
    }
    
    /// Generate a short summary of the message
    pub fn get_summary(&self, max_length: usize) -> String {
        if self.content.len() <= max_length {
            self.content.clone()
        } else {
            format!("{}...", &self.content[..max_length.saturating_sub(3)])
        }
    }
    
    /// Convert to JSON for storage or transmission
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
    
    /// Create from JSON
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}

impl Default for BitchatMessage {
    fn default() -> Self {
        Self::new_system("Default message".to_string())
    }
}