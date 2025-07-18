//! BitChat Binary Protocol Implementation
//! 
//! Implements the binary protocol for efficient Bluetooth LE communication.
//! Based on the Swift implementation with cross-platform compatibility.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Protocol version for compatibility checking
pub const PROTOCOL_VERSION: u8 = 1;

/// Service UUID for BitChat Bluetooth LE service
pub const SERVICE_UUID: &str = "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C";

/// Characteristic UUID for BitChat message exchange
pub const CHARACTERISTIC_UUID: &str = "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D";

/// Maximum message payload size (accounting for BLE MTU limitations)
pub const MAX_PAYLOAD_SIZE: usize = 512;

/// Maximum Time-To-Live for message routing
pub const MAX_TTL: u8 = 7;

/// Message type enumeration matching Swift implementation
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum MessageType {
    Announce = 0x01,        // Peer presence and identity
    Message = 0x04,         // User messages (broadcast/private/channel)
    DeliveryAck = 0x0A,     // Message delivery acknowledgment
    DeliveryRequest = 0x0B, // Request delivery status
    DeliveryStatus = 0x0C,  // Delivery status response
    ChannelList = 0x08,     // Channel list announcement
    NoiseInit = 0x10,       // Noise protocol handshake init
    NoiseResponse = 0x11,   // Noise protocol handshake response
    NoiseFinish = 0x12,     // Noise protocol handshake finish
    ChannelJoin = 0x14,     // Channel join request
    ChannelLeave = 0x15,    // Channel leave notification
    ChannelPassword = 0x16, // Channel password change
    ChannelTransfer = 0x17, // Channel ownership transfer
}

impl From<u8> for MessageType {
    fn from(value: u8) -> Self {
        match value {
            0x01 => MessageType::Announce,
            0x04 => MessageType::Message,
            0x0A => MessageType::DeliveryAck,
            0x0B => MessageType::DeliveryRequest,
            0x0C => MessageType::DeliveryStatus,
            0x08 => MessageType::ChannelList,
            0x10 => MessageType::NoiseInit,
            0x11 => MessageType::NoiseResponse,
            0x12 => MessageType::NoiseFinish,
            0x14 => MessageType::ChannelJoin,
            0x15 => MessageType::ChannelLeave,
            0x16 => MessageType::ChannelPassword,
            0x17 => MessageType::ChannelTransfer,
            _ => MessageType::Message, // Default fallback
        }
    }
}

/// Message flags for optional features
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessageFlags {
    pub has_recipient: bool,
    pub has_signature: bool,
    pub is_compressed: bool,
    pub is_encrypted: bool,
    pub reserved: u8, // For future expansion
}

impl MessageFlags {
    pub fn new() -> Self {
        Self {
            has_recipient: false,
            has_signature: false,
            is_compressed: false,
            is_encrypted: false,
            reserved: 0,
        }
    }
    
    pub fn to_byte(&self) -> u8 {
        let mut flags = 0u8;
        if self.has_recipient { flags |= 0x01; }
        if self.has_signature { flags |= 0x02; }
        if self.is_compressed { flags |= 0x04; }
        if self.is_encrypted { flags |= 0x08; }
        flags |= (self.reserved & 0x0F) << 4;
        flags
    }
    
    pub fn from_byte(byte: u8) -> Self {
        Self {
            has_recipient: (byte & 0x01) != 0,
            has_signature: (byte & 0x02) != 0,
            is_compressed: (byte & 0x04) != 0,
            is_encrypted: (byte & 0x08) != 0,
            reserved: (byte >> 4) & 0x0F,
        }
    }
}

/// Protocol message structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtocolMessage {
    pub id: Uuid,
    pub version: u8,
    pub message_type: MessageType,
    pub ttl: u8,
    pub timestamp: u64,
    pub flags: MessageFlags,
    pub sender_id: [u8; 8],
    pub recipient_id: Option<[u8; 8]>,
    pub payload: Vec<u8>,
    #[serde(with = "signature_option")]
    pub signature: Option<[u8; 64]>,
}

impl ProtocolMessage {
    /// Create a new protocol message
    pub fn new(
        message_type: MessageType,
        sender_id: [u8; 8],
        payload: Vec<u8>,
    ) -> Self {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
            
        Self {
            id: Uuid::new_v4(),
            version: PROTOCOL_VERSION,
            message_type,
            ttl: MAX_TTL,
            timestamp,
            flags: MessageFlags::new(),
            sender_id,
            recipient_id: None,
            payload,
            signature: None,
        }
    }
    
    /// Set recipient for private messages
    pub fn with_recipient(mut self, recipient_id: [u8; 8]) -> Self {
        self.recipient_id = Some(recipient_id);
        self.flags.has_recipient = true;
        self
    }
    
    /// Set compression flag
    pub fn with_compression(mut self, compressed: bool) -> Self {
        self.flags.is_compressed = compressed;
        self
    }
    
    /// Set encryption flag
    pub fn with_encryption(mut self, encrypted: bool) -> Self {
        self.flags.is_encrypted = encrypted;
        self
    }
    
    /// Add signature to message
    pub fn with_signature(mut self, signature: [u8; 64]) -> Self {
        self.signature = Some(signature);
        self.flags.has_signature = true;
        self
    }
    
    /// Decrease TTL for message forwarding
    pub fn decrease_ttl(mut self) -> Option<Self> {
        if self.ttl > 0 {
            self.ttl -= 1;
            Some(self)
        } else {
            None
        }
    }
    
    /// Calculate message size for BLE transmission
    pub fn calculate_size(&self) -> usize {
        let mut size = 13; // Fixed header size
        size += 8; // Sender ID
        
        if self.flags.has_recipient {
            size += 8; // Recipient ID
        }
        
        size += self.payload.len();
        
        if self.flags.has_signature {
            size += 64; // Signature
        }
        
        size
    }
    
    /// Check if message fits in BLE packet
    pub fn fits_in_ble_packet(&self) -> bool {
        self.calculate_size() <= MAX_PAYLOAD_SIZE
    }
}

/// BitChat protocol handler
pub struct BitchatProtocol;

impl BitchatProtocol {
    /// Encode protocol message to binary format
    pub fn encode(message: &ProtocolMessage) -> Result<Vec<u8>> {
        let mut buffer = Vec::new();
        
        // Header (13 bytes)
        buffer.push(message.version);           // 1 byte
        buffer.push(message.message_type as u8); // 1 byte
        buffer.push(message.ttl);               // 1 byte
        buffer.extend_from_slice(&message.timestamp.to_be_bytes()); // 8 bytes
        buffer.push(message.flags.to_byte());   // 1 byte
        
        // Payload length (2 bytes)
        let payload_len = message.payload.len() as u16;
        buffer.extend_from_slice(&payload_len.to_be_bytes());
        
        // Sender ID (8 bytes)
        buffer.extend_from_slice(&message.sender_id);
        
        // Optional recipient ID (8 bytes)
        if let Some(recipient_id) = message.recipient_id {
            buffer.extend_from_slice(&recipient_id);
        }
        
        // Payload (variable length)
        buffer.extend_from_slice(&message.payload);
        
        // Optional signature (64 bytes)
        if let Some(signature) = message.signature {
            buffer.extend_from_slice(&signature);
        }
        
        if buffer.len() > MAX_PAYLOAD_SIZE {
            bail!("Message too large for BLE transmission: {} bytes", buffer.len());
        }
        
        Ok(buffer)
    }
    
    /// Decode binary data to protocol message
    pub fn decode(data: &[u8]) -> Result<ProtocolMessage> {
        if data.len() < 13 {
            bail!("Invalid message: too short");
        }
        
        let mut offset = 0;
        
        // Parse header
        let version = data[offset];
        offset += 1;
        
        if version != PROTOCOL_VERSION {
            bail!("Unsupported protocol version: {}", version);
        }
        
        let message_type = MessageType::from(data[offset]);
        offset += 1;
        
        let ttl = data[offset];
        offset += 1;
        
        let timestamp = u64::from_be_bytes([
            data[offset], data[offset + 1], data[offset + 2], data[offset + 3],
            data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7],
        ]);
        offset += 8;
        
        let flags = MessageFlags::from_byte(data[offset]);
        offset += 1;
        
        // Parse payload length
        if offset + 2 > data.len() {
            bail!("Invalid message: missing payload length");
        }
        
        let payload_len = u16::from_be_bytes([data[offset], data[offset + 1]]) as usize;
        offset += 2;
        
        // Parse sender ID
        if offset + 8 > data.len() {
            bail!("Invalid message: missing sender ID");
        }
        
        let mut sender_id = [0u8; 8];
        sender_id.copy_from_slice(&data[offset..offset + 8]);
        offset += 8;
        
        // Parse optional recipient ID
        let recipient_id = if flags.has_recipient {
            if offset + 8 > data.len() {
                bail!("Invalid message: missing recipient ID");
            }
            
            let mut recipient = [0u8; 8];
            recipient.copy_from_slice(&data[offset..offset + 8]);
            offset += 8;
            Some(recipient)
        } else {
            None
        };
        
        // Parse payload
        if offset + payload_len > data.len() {
            bail!("Invalid message: payload length mismatch");
        }
        
        let payload = data[offset..offset + payload_len].to_vec();
        offset += payload_len;
        
        // Parse optional signature
        let signature = if flags.has_signature {
            if offset + 64 > data.len() {
                bail!("Invalid message: missing signature");
            }
            
            let mut sig = [0u8; 64];
            sig.copy_from_slice(&data[offset..offset + 64]);
            Some(sig)
        } else {
            None
        };
        
        Ok(ProtocolMessage {
            id: Uuid::new_v4(), // Generate new ID for decoded message
            version,
            message_type,
            ttl,
            timestamp,
            flags,
            sender_id,
            recipient_id,
            payload,
            signature,
        })
    }
    
    /// Create announce message for peer discovery
    pub fn create_announce(sender_id: [u8; 8], nickname: &str) -> ProtocolMessage {
        let payload = serde_json::json!({
            "nickname": nickname,
            "timestamp": SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
        }).to_string().into_bytes();
        
        ProtocolMessage::new(MessageType::Announce, sender_id, payload)
    }
    
    /// Create user message (broadcast, private, or channel)
    pub fn create_message(
        sender_id: [u8; 8],
        content: &str,
        recipient_id: Option<[u8; 8]>,
        channel: Option<&str>,
    ) -> ProtocolMessage {
        let payload = serde_json::json!({
            "content": content,
            "channel": channel,
            "timestamp": SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
        }).to_string().into_bytes();
        
        let mut message = ProtocolMessage::new(MessageType::Message, sender_id, payload);
        
        if let Some(recipient) = recipient_id {
            message = message.with_recipient(recipient);
        }
        
        message
    }
    
    /// Create delivery acknowledgment
    pub fn create_delivery_ack(
        sender_id: [u8; 8],
        message_id: Uuid,
        recipient_id: [u8; 8],
    ) -> ProtocolMessage {
        let payload = serde_json::json!({
            "message_id": message_id,
            "status": "delivered",
            "timestamp": SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
        }).to_string().into_bytes();
        
        ProtocolMessage::new(MessageType::DeliveryAck, sender_id, payload)
            .with_recipient(recipient_id)
    }
}

// Custom serialization for Option<[u8; 64]>
mod signature_option {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S>(sig: &Option<[u8; 64]>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match sig {
            Some(bytes) => bytes.as_slice().serialize(serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<[u8; 64]>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let opt: Option<Vec<u8>> = Option::deserialize(deserializer)?;
        match opt {
            Some(vec) => {
                if vec.len() == 64 {
                    let mut array = [0u8; 64];
                    array.copy_from_slice(&vec);
                    Ok(Some(array))
                } else {
                    Err(serde::de::Error::custom("Invalid signature length"))
                }
            }
            None => Ok(None),
        }
    }
}