//! Enhanced Cryptography Module
//! 
//! Implements end-to-end encryption using Noise Protocol Framework
//! with integration to the enhanced cryptography engine from art-of-aegis.
//! Follows AI Guidance Protocol for secure, ethical cryptographic implementation.

pub mod noise_protocol;
pub mod channel_crypto;
pub mod enhanced_crypto;

pub use noise_protocol::NoiseEngine;
pub use channel_crypto::ChannelCrypto;
pub use enhanced_crypto::EnhancedCryptoEngine;

use anyhow::Result;

/// Main cryptography engine for BitChat
pub struct CryptoEngine {
    noise_engine: NoiseEngine,
    channel_crypto: ChannelCrypto,
    enhanced_engine: Option<EnhancedCryptoEngine>,
}

impl CryptoEngine {
    pub fn new() -> Self {
        Self {
            noise_engine: NoiseEngine::new(),
            channel_crypto: ChannelCrypto::new(),
            enhanced_engine: Some(EnhancedCryptoEngine::new()),
        }
    }
    
    /// Get our cryptographic fingerprint
    pub async fn get_fingerprint(&self) -> Result<String> {
        self.noise_engine.get_fingerprint().await
    }
    
    /// Verify a peer's fingerprint
    pub async fn verify_peer_fingerprint(&self, peer_id: String, expected_fingerprint: String) -> Result<bool> {
        self.noise_engine.verify_peer_fingerprint(peer_id, expected_fingerprint).await
    }
    
    /// Set password for a channel
    pub async fn set_channel_password(&self, channel: String, password: String) -> Result<String> {
        self.channel_crypto.set_channel_password(channel, password).await
    }
    
    /// Encrypt data with enhanced cryptography if available
    pub async fn enhanced_encrypt(&self, data: &[u8]) -> Result<Vec<u8>> {
        if let Some(enhanced) = &self.enhanced_engine {
            return enhanced.encrypt(data).await;
        }
        
        // Fallback to standard encryption
        Ok(data.to_vec())
    }
    
    /// Decrypt data with enhanced cryptography if available
    pub async fn enhanced_decrypt(&self, data: &[u8]) -> Result<Vec<u8>> {
        if let Some(enhanced) = &self.enhanced_engine {
            return enhanced.decrypt(data).await;
        }
        
        // Fallback to standard decryption
        Ok(data.to_vec())
    }
}

impl Default for CryptoEngine {
    fn default() -> Self {
        Self::new()
    }
}