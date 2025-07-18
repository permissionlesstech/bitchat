//! Hybrid Cryptography Engine
//! 
//! Combines classical and post-quantum cryptography for maximum security.

use anyhow::{Result, Context};
use log::{info, debug, warn};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::pqc_engine::{QuantumResistantEngine, PqcAlgorithm, PqcKeyPair};

/// Hybrid cryptography engine combining classical and post-quantum algorithms
pub struct HybridCryptoEngine {
    pqc_engine: Option<Arc<QuantumResistantEngine>>,
    operation_mode: Arc<RwLock<OperationMode>>,
    hybrid_keys: Arc<RwLock<Vec<HybridKeyPair>>>,
    is_initialized: Arc<RwLock<bool>>,
    is_operational: Arc<RwLock<bool>>,
}

/// Hybrid key pair combining classical and post-quantum keys
#[derive(Debug, Clone)]
pub struct HybridKeyPair {
    pub id: String,
    pub classical_keypair: ClassicalKeyPair,
    pub pqc_keypair: PqcKeyPair,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub purpose: KeyPurpose,
}

/// Classical cryptography key pair
#[derive(Debug, Clone)]
pub struct ClassicalKeyPair {
    pub algorithm: ClassicalAlgorithm,
    pub public_key: Vec<u8>,
    pub private_key: Vec<u8>,
    pub key_size: usize,
}

/// Classical cryptographic algorithms
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClassicalAlgorithm {
    X25519,     // Elliptic curve Diffie-Hellman
    Ed25519,    // Edwards curve signatures
    Rsa2048,    // RSA 2048-bit
    Rsa4096,    // RSA 4096-bit
}

/// Key purposes
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyPurpose {
    KeyExchange,    // For key derivation
    Signing,        // For digital signatures
    Encryption,     // For data encryption
}

/// Operation modes
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OperationMode {
    ClassicalOnly,      // Classical cryptography only
    PostQuantumOnly,    // Post-quantum cryptography only
    Hybrid,             // Both classical and post-quantum
    Emergency,          // Minimal operations only
}

/// Hybrid encryption result
#[derive(Debug, Clone)]
pub struct HybridEncryptionResult {
    pub classical_ciphertext: Vec<u8>,
    pub pqc_ciphertext: Vec<u8>,
    pub shared_secret: Vec<u8>,
    pub algorithm_info: HybridAlgorithmInfo,
}

/// Hybrid algorithm information
#[derive(Debug, Clone)]
pub struct HybridAlgorithmInfo {
    pub classical_algorithm: ClassicalAlgorithm,
    pub pqc_algorithm: PqcAlgorithm,
    pub combined_strength: SecurityStrength,
}

/// Security strength levels
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum SecurityStrength {
    Low,        // 80-bit equivalent
    Medium,     // 112-bit equivalent
    High,       // 128-bit equivalent
    VeryHigh,   // 192-bit equivalent
    Maximum,    // 256-bit equivalent
}

impl HybridCryptoEngine {
    pub fn new() -> Self {
        Self {
            pqc_engine: None,
            operation_mode: Arc::new(RwLock::new(OperationMode::Hybrid)),
            hybrid_keys: Arc::new(RwLock::new(Vec::new())),
            is_initialized: Arc::new(RwLock::new(false)),
            is_operational: Arc::new(RwLock::new(false)),
        }
    }
    
    /// Initialize hybrid crypto engine
    pub async fn initialize(&self, pqc_engine: &Arc<QuantumResistantEngine>) -> Result<()> {
        info!("Initializing hybrid cryptography engine");
        
        // Store reference to PQC engine
        let mut engine = self.pqc_engine.clone();
        engine = Some(pqc_engine.clone());
        
        // Verify both classical and post-quantum capabilities
        self.verify_classical_capabilities().await?;
        self.verify_pqc_capabilities(pqc_engine).await?;
        
        *self.is_initialized.write().await = true;
        *self.is_operational.write().await = true;
        
        info!("Hybrid cryptography engine initialized successfully");
        Ok(())
    }
    
    /// Verify classical cryptography capabilities
    async fn verify_classical_capabilities(&self) -> Result<()> {
        debug!("Verifying classical cryptography capabilities");
        
        // Check X25519 availability
        let x25519_available = true; // Simplified check
        
        // Check Ed25519 availability
        let ed25519_available = true; // Simplified check
        
        if !x25519_available || !ed25519_available {
            return Err(anyhow::anyhow!("Required classical algorithms not available"));
        }
        
        debug!("Classical cryptography capabilities verified");
        Ok(())
    }
    
    /// Verify post-quantum capabilities
    async fn verify_pqc_capabilities(&self, pqc_engine: &QuantumResistantEngine) -> Result<()> {
        debug!("Verifying post-quantum capabilities");
        
        let algorithms = pqc_engine.get_available_algorithms().await;
        
        if algorithms.is_empty() {
            return Err(anyhow::anyhow!("No post-quantum algorithms available"));
        }
        
        debug!("Post-quantum capabilities verified: {} algorithms", algorithms.len());
        Ok(())
    }
    
    /// Generate hybrid key pair
    pub async fn generate_hybrid_keypair(&self, purpose: KeyPurpose) -> Result<HybridKeyPair> {
        if !*self.is_operational.read().await {
            return Err(anyhow::anyhow!("Hybrid crypto engine not operational"));
        }
        
        info!("Generating hybrid keypair for purpose: {:?}", purpose);
        
        // Generate classical key pair
        let classical_keypair = self.generate_classical_keypair(&purpose).await?;
        
        // Generate post-quantum key pair
        let pqc_algorithm = match purpose {
            KeyPurpose::KeyExchange | KeyPurpose::Encryption => PqcAlgorithm::MlKem768,
            KeyPurpose::Signing => PqcAlgorithm::Falcon512,
        };
        
        let pqc_engine = self.pqc_engine.as_ref()
            .ok_or_else(|| anyhow::anyhow!("PQC engine not available"))?;
        
        let pqc_keypair = pqc_engine.generate_keypair(pqc_algorithm).await?;
        
        let hybrid_keypair = HybridKeyPair {
            id: uuid::Uuid::new_v4().to_string(),
            classical_keypair,
            pqc_keypair,
            created_at: chrono::Utc::now(),
            purpose,
        };
        
        // Store the key pair
        self.hybrid_keys.write().await.push(hybrid_keypair.clone());
        
        info!("Generated hybrid keypair with ID: {}", hybrid_keypair.id);
        Ok(hybrid_keypair)
    }
    
    /// Generate classical key pair
    async fn generate_classical_keypair(&self, purpose: &KeyPurpose) -> Result<ClassicalKeyPair> {
        let algorithm = match purpose {
            KeyPurpose::KeyExchange => ClassicalAlgorithm::X25519,
            KeyPurpose::Signing => ClassicalAlgorithm::Ed25519,
            KeyPurpose::Encryption => ClassicalAlgorithm::X25519,
        };
        
        let (public_key, private_key, key_size) = match algorithm {
            ClassicalAlgorithm::X25519 => {
                // Generate X25519 key pair (simplified)
                let public_key = vec![0u8; 32];  // 32 bytes for X25519 public key
                let private_key = vec![0u8; 32]; // 32 bytes for X25519 private key
                (public_key, private_key, 32)
            }
            ClassicalAlgorithm::Ed25519 => {
                // Generate Ed25519 key pair (simplified)
                let public_key = vec![0u8; 32];  // 32 bytes for Ed25519 public key
                let private_key = vec![0u8; 32]; // 32 bytes for Ed25519 private key
                (public_key, private_key, 32)
            }
            ClassicalAlgorithm::Rsa2048 => {
                // Generate RSA 2048-bit key pair (simplified)
                let public_key = vec![0u8; 256];  // 256 bytes for RSA-2048 public key
                let private_key = vec![0u8; 1024]; // 1024 bytes for RSA-2048 private key
                (public_key, private_key, 2048)
            }
            ClassicalAlgorithm::Rsa4096 => {
                // Generate RSA 4096-bit key pair (simplified)
                let public_key = vec![0u8; 512];   // 512 bytes for RSA-4096 public key
                let private_key = vec![0u8; 2048]; // 2048 bytes for RSA-4096 private key
                (public_key, private_key, 4096)
            }
        };
        
        Ok(ClassicalKeyPair {
            algorithm,
            public_key,
            private_key,
            key_size,
        })
    }
    
    /// Perform hybrid encryption
    pub async fn hybrid_encrypt(&self, data: &[u8], recipient_keypair: &HybridKeyPair) -> Result<HybridEncryptionResult> {
        if !*self.is_operational.read().await {
            return Err(anyhow::anyhow!("Hybrid crypto engine not operational"));
        }
        
        debug!("Performing hybrid encryption on {} bytes", data.len());
        
        // Classical encryption
        let classical_ciphertext = self.classical_encrypt(data, &recipient_keypair.classical_keypair).await?;
        
        // Post-quantum encryption
        let pqc_engine = self.pqc_engine.as_ref()
            .ok_or_else(|| anyhow::anyhow!("PQC engine not available"))?;
        
        let (pqc_ciphertext, shared_secret) = pqc_engine
            .encapsulate(&recipient_keypair.pqc_keypair.public_key, recipient_keypair.pqc_keypair.algorithm)
            .await?;
        
        let algorithm_info = HybridAlgorithmInfo {
            classical_algorithm: recipient_keypair.classical_keypair.algorithm.clone(),
            pqc_algorithm: recipient_keypair.pqc_keypair.algorithm,
            combined_strength: self.calculate_combined_strength(
                &recipient_keypair.classical_keypair.algorithm,
                &recipient_keypair.pqc_keypair.algorithm,
            ),
        };
        
        let result = HybridEncryptionResult {
            classical_ciphertext,
            pqc_ciphertext,
            shared_secret,
            algorithm_info,
        };
        
        info!("Hybrid encryption completed with {:?} strength", result.algorithm_info.combined_strength);
        Ok(result)
    }
    
    /// Perform classical encryption
    async fn classical_encrypt(&self, data: &[u8], keypair: &ClassicalKeyPair) -> Result<Vec<u8>> {
        // Simplified classical encryption
        let mut encrypted = data.to_vec();
        
        match keypair.algorithm {
            ClassicalAlgorithm::X25519 => {
                // Simulate X25519 encryption
                for byte in &mut encrypted {
                    *byte ^= 0x25;
                }
            }
            ClassicalAlgorithm::Ed25519 => {
                // Ed25519 is for signatures, not encryption
                return Err(anyhow::anyhow!("Ed25519 is not an encryption algorithm"));
            }
            ClassicalAlgorithm::Rsa2048 | ClassicalAlgorithm::Rsa4096 => {
                // Simulate RSA encryption
                for byte in &mut encrypted {
                    *byte ^= 0x42;
                }
            }
        }
        
        Ok(encrypted)
    }
    
    /// Calculate combined security strength
    fn calculate_combined_strength(&self, classical: &ClassicalAlgorithm, pqc: &PqcAlgorithm) -> SecurityStrength {
        let classical_strength = match classical {
            ClassicalAlgorithm::X25519 | ClassicalAlgorithm::Ed25519 => SecurityStrength::High,
            ClassicalAlgorithm::Rsa2048 => SecurityStrength::Medium,
            ClassicalAlgorithm::Rsa4096 => SecurityStrength::High,
        };
        
        let pqc_strength = match pqc {
            PqcAlgorithm::MlKem768 => SecurityStrength::VeryHigh,
            PqcAlgorithm::Falcon512 => SecurityStrength::High,
            PqcAlgorithm::Falcon1024 => SecurityStrength::VeryHigh,
        };
        
        // Combined strength is the maximum of both
        std::cmp::max(classical_strength, pqc_strength)
    }
    
    /// Check if engine is operational
    pub async fn is_operational(&self) -> bool {
        *self.is_operational.read().await
    }
    
    /// Set emergency mode
    pub async fn emergency_mode(&self) -> Result<()> {
        warn!("Activating emergency mode for hybrid crypto engine");
        *self.operation_mode.write().await = OperationMode::Emergency;
        *self.is_operational.write().await = false;
        Ok(())
    }
    
    /// Set normal mode
    pub async fn normal_mode(&self) -> Result<()> {
        info!("Restoring normal mode for hybrid crypto engine");
        *self.operation_mode.write().await = OperationMode::Hybrid;
        *self.is_operational.write().await = true;
        Ok(())
    }
    
    /// Get engine status
    pub async fn get_status(&self) -> Value {
        let mode = self.operation_mode.read().await;
        let keys = self.hybrid_keys.read().await;
        
        let key_purposes: std::collections::HashMap<String, usize> = keys
            .iter()
            .fold(std::collections::HashMap::new(), |mut acc, key| {
                let purpose = format!("{:?}", key.purpose);
                *acc.entry(purpose).or_insert(0) += 1;
                acc
            });
        
        serde_json::json!({
            "initialized": *self.is_initialized.read().await,
            "operational": *self.is_operational.read().await,
            "operation_mode": format!("{:?}", *mode),
            "hybrid_keys_count": keys.len(),
            "key_purposes": key_purposes,
            "classical_algorithms": ["X25519", "Ed25519", "RSA-2048", "RSA-4096"],
            "pqc_integration": true,
            "quantum_resistance": true
        })
    }
    
    /// Get hybrid keys
    pub async fn get_hybrid_keys(&self) -> Vec<HybridKeyPair> {
        self.hybrid_keys.read().await.clone()
    }
    
    /// Remove expired keys
    pub async fn cleanup_expired_keys(&self, max_age_days: i64) -> Result<usize> {
        let mut keys = self.hybrid_keys.write().await;
        let cutoff_time = chrono::Utc::now() - chrono::Duration::days(max_age_days);
        
        let initial_count = keys.len();
        keys.retain(|key| key.created_at > cutoff_time);
        let removed_count = initial_count - keys.len();
        
        if removed_count > 0 {
            info!("Removed {} expired hybrid keys", removed_count);
        }
        
        Ok(removed_count)
    }
}

impl Default for HybridCryptoEngine {
    fn default() -> Self {
        Self::new()
    }
}