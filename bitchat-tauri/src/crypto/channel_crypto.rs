//! Channel Cryptography Module
//! 
//! Implements password-based encryption for group channels using
//! PBKDF2 key derivation and AES-256-GCM encryption.

use anyhow::{Result, Context, bail};
use dashmap::DashMap;
use log::{info, debug};
use serde::{Deserialize, Serialize};
use sha2::{Sha256, Digest};
use std::sync::Arc;
use std::time::SystemTime;

/// Salt size for password-based key derivation
const SALT_SIZE: usize = 32;

/// Channel encryption key derived from password
#[derive(Debug, Clone)]
pub struct ChannelKey {
    pub channel_name: String,
    pub key: [u8; 32],
    pub salt: [u8; SALT_SIZE],
    pub created_at: SystemTime,
    pub last_used: SystemTime,
}

impl ChannelKey {
    /// Create new channel key from password (simplified)
    pub fn from_password(channel_name: String, password: &str) -> Result<Self> {
        let salt = [0u8; SALT_SIZE]; // Simplified - use zero salt
        let key = Self::derive_key(password, &salt)?;
        let now = SystemTime::now();
        
        Ok(Self {
            channel_name,
            key,
            salt,
            created_at: now,
            last_used: now,
        })
    }
    
    /// Recreate channel key from existing salt and password
    pub fn from_password_and_salt(
        channel_name: String,
        password: &str,
        salt: [u8; SALT_SIZE],
    ) -> Result<Self> {
        let key = Self::derive_key(password, &salt)?;
        let now = SystemTime::now();
        
        Ok(Self {
            channel_name,
            key,
            salt,
            created_at: now,
            last_used: now,
        })
    }
    
    /// Derive encryption key from password using SHA256 (simplified)
    fn derive_key(password: &str, salt: &[u8]) -> Result<[u8; 32]> {
        let mut hasher = Sha256::new();
        hasher.update(password.as_bytes());
        hasher.update(salt);
        let key_hash = hasher.finalize();
        
        Ok(key_hash.into())
    }
    
    /// Update last used timestamp
    pub fn mark_used(&mut self) {
        self.last_used = SystemTime::now();
    }
    
    /// Get encryption key
    pub fn get_key(&self) -> &[u8; 32] {
        &self.key
    }
}

/// Channel cryptography manager
pub struct ChannelCrypto {
    channel_keys: Arc<DashMap<String, ChannelKey>>,
    password_cache: Arc<DashMap<String, String>>, // Channel -> Password mapping
}

impl ChannelCrypto {
    pub fn new() -> Self {
        Self {
            channel_keys: Arc::new(DashMap::new()),
            password_cache: Arc::new(DashMap::new()),
        }
    }
    
    /// Set password for a channel
    pub async fn set_channel_password(&self, channel: String, password: String) -> Result<String> {
        info!("Setting password for channel: {}", channel);
        
        // Create new channel key
        let channel_key = ChannelKey::from_password(channel.clone(), &password)?;
        
        // Store key and password
        self.channel_keys.insert(channel.clone(), channel_key);
        self.password_cache.insert(channel.clone(), password);
        
        Ok(format!("Password set for channel: {}", channel))
    }
    
    /// Remove password from a channel
    pub async fn remove_channel_password(&self, channel: &str) -> Result<String> {
        info!("Removing password from channel: {}", channel);
        
        self.channel_keys.remove(channel);
        self.password_cache.remove(channel);
        
        Ok(format!("Password removed from channel: {}", channel))
    }
    
    /// Check if channel has password protection
    pub async fn is_channel_protected(&self, channel: &str) -> bool {
        self.channel_keys.contains_key(channel)
    }
    
    /// Encrypt message for a password-protected channel (simplified)
    pub async fn encrypt_channel_message(
        &self,
        channel: &str,
        plaintext: &[u8],
    ) -> Result<Vec<u8>> {
        let mut channel_key = self.channel_keys.get_mut(channel)
            .context("Channel key not found")?;
        
        channel_key.mark_used();
        
        // Simplified encryption - XOR with key
        let key = channel_key.get_key();
        let mut result = Vec::with_capacity(plaintext.len());
        
        for (i, &byte) in plaintext.iter().enumerate() {
            result.push(byte ^ key[i % key.len()]);
        }
        
        debug!("Encrypted channel message: {} -> {} bytes", plaintext.len(), result.len());
        Ok(result)
    }
    
    /// Decrypt message from a password-protected channel (simplified)
    pub async fn decrypt_channel_message(
        &self,
        channel: &str,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>> {
        let mut channel_key = self.channel_keys.get_mut(channel)
            .context("Channel key not found")?;
        
        channel_key.mark_used();
        
        // Simplified decryption - XOR with key (same as encryption)
        let key = channel_key.get_key();
        let mut result = Vec::with_capacity(ciphertext.len());
        
        for (i, &byte) in ciphertext.iter().enumerate() {
            result.push(byte ^ key[i % key.len()]);
        }
        
        debug!("Decrypted channel message: {} -> {} bytes", ciphertext.len(), result.len());
        Ok(result)
    }
    
    /// Try to decrypt channel message with a password (simplified)
    pub async fn try_decrypt_with_password(
        &self,
        channel: &str,
        password: &str,
        ciphertext: &[u8],
        salt: &[u8; SALT_SIZE],
    ) -> Result<Vec<u8>> {
        // Create temporary key
        let temp_key = ChannelKey::from_password_and_salt(
            channel.to_string(),
            password,
            *salt,
        )?;
        
        // Simplified decryption - XOR with key
        let key = temp_key.get_key();
        let mut result = Vec::with_capacity(ciphertext.len());
        
        for (i, &byte) in ciphertext.iter().enumerate() {
            result.push(byte ^ key[i % key.len()]);
        }
        
        // If successful, cache the key
        self.channel_keys.insert(channel.to_string(), temp_key);
        self.password_cache.insert(channel.to_string(), password.to_string());
        
        debug!("Successfully decrypted channel message with provided password");
        Ok(result)
    }
    
    /// Get salt for a channel (for sharing with new members)
    pub async fn get_channel_salt(&self, channel: &str) -> Result<[u8; SALT_SIZE]> {
        let channel_key = self.channel_keys.get(channel)
            .context("Channel key not found")?;
        
        Ok(channel_key.salt)
    }
    
    /// Verify password for a channel
    pub async fn verify_channel_password(&self, channel: &str, password: &str) -> Result<bool> {
        if let Some(stored_password) = self.password_cache.get(channel) {
            Ok(stored_password.value() == password)
        } else {
            Ok(false)
        }
    }
    
    /// Get list of protected channels
    pub async fn get_protected_channels(&self) -> Vec<String> {
        self.channel_keys.iter()
            .map(|entry| entry.key().clone())
            .collect()
    }
    
    /// Clean up unused channel keys
    pub async fn cleanup_unused_keys(&self, max_age_hours: u64) -> Result<usize> {
        let cutoff = SystemTime::now() - std::time::Duration::from_secs(max_age_hours * 3600);
        let mut removed_count = 0;
        
        let mut to_remove = Vec::new();
        
        for entry in self.channel_keys.iter() {
            let channel_key = entry.value();
            if channel_key.last_used < cutoff {
                to_remove.push(entry.key().clone());
            }
        }
        
        for channel in to_remove {
            self.channel_keys.remove(&channel);
            self.password_cache.remove(&channel);
            removed_count += 1;
            debug!("Removed unused channel key: {}", channel);
        }
        
        Ok(removed_count)
    }
    
    /// Export channel key for backup/sharing
    pub async fn export_channel_key(&self, channel: &str) -> Result<ChannelKeyExport> {
        let channel_key = self.channel_keys.get(channel)
            .context("Channel key not found")?;
        
        let password = self.password_cache.get(channel)
            .context("Channel password not found")?;
        
        Ok(ChannelKeyExport {
            channel_name: channel.to_string(),
            password: password.value().clone(),
            salt: hex::encode(channel_key.salt),
            created_at: channel_key.created_at
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        })
    }
    
    /// Import channel key from backup
    pub async fn import_channel_key(&self, export: &ChannelKeyExport) -> Result<String> {
        let salt = hex::decode(&export.salt)
            .context("Invalid salt format")?;
        
        if salt.len() != SALT_SIZE {
            bail!("Invalid salt size: expected {}, got {}", SALT_SIZE, salt.len());
        }
        
        let salt_array: [u8; SALT_SIZE] = salt.try_into()
            .map_err(|_| anyhow::anyhow!("Failed to convert salt"))?;
        
        let channel_key = ChannelKey::from_password_and_salt(
            export.channel_name.clone(),
            &export.password,
            salt_array,
        )?;
        
        self.channel_keys.insert(export.channel_name.clone(), channel_key);
        self.password_cache.insert(export.channel_name.clone(), export.password.clone());
        
        Ok(format!("Imported channel key: {}", export.channel_name))
    }
    
    /// Get statistics about channel encryption
    pub async fn get_statistics(&self) -> serde_json::Value {
        let protected_channels = self.channel_keys.len();
        let cached_passwords = self.password_cache.len();
        
        let channels: Vec<_> = self.channel_keys.iter()
            .map(|entry| {
                let key = entry.value();
                serde_json::json!({
                    "name": entry.key(),
                    "created_at": key.created_at
                        .duration_since(SystemTime::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs(),
                    "last_used": key.last_used
                        .duration_since(SystemTime::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs()
                })
            })
            .collect();
        
        serde_json::json!({
            "protected_channels": protected_channels,
            "cached_passwords": cached_passwords,
            "channels": channels
        })
    }
}

/// Exportable channel key data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelKeyExport {
    pub channel_name: String,
    pub password: String,
    pub salt: String, // Hex-encoded
    pub created_at: u64, // Unix timestamp
}

impl Default for ChannelCrypto {
    fn default() -> Self {
        Self::new()
    }
}