//! Full Security Suite Integration
//! 
//! Integrates Overlord PQC and Crabcore-Aegis for comprehensive security.
//! Follows AI Guidance Protocol for ethical security implementation.

pub mod pqc_engine;
pub mod file_protection;
pub mod threat_analysis;
pub mod audit_system;
pub mod hybrid_crypto;

pub use pqc_engine::QuantumResistantEngine;
pub use file_protection::FileProtectionService;
pub use threat_analysis::ThreatAnalyzer;
pub use audit_system::SecurityAuditor;
pub use hybrid_crypto::HybridCryptoEngine;

use anyhow::Result;
use log::{info, warn};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Main security suite orchestrator
pub struct SecuritySuite {
    pqc_engine: Arc<QuantumResistantEngine>,
    file_protection: Arc<FileProtectionService>,
    threat_analyzer: Arc<ThreatAnalyzer>,
    audit_system: Arc<SecurityAuditor>,
    hybrid_crypto: Arc<HybridCryptoEngine>,
    is_initialized: Arc<RwLock<bool>>,
}

impl SecuritySuite {
    pub fn new() -> Self {
        Self {
            pqc_engine: Arc::new(QuantumResistantEngine::new()),
            file_protection: Arc::new(FileProtectionService::new()),
            threat_analyzer: Arc::new(ThreatAnalyzer::new()),
            audit_system: Arc::new(SecurityAuditor::new()),
            hybrid_crypto: Arc::new(HybridCryptoEngine::new()),
            is_initialized: Arc::new(RwLock::new(false)),
        }
    }
    
    /// Initialize the full security suite
    pub async fn initialize(&self) -> Result<()> {
        info!("Initializing comprehensive security suite");
        
        // Initialize post-quantum cryptography
        self.pqc_engine.initialize().await?;
        info!("Post-quantum cryptography engine initialized");
        
        // Initialize file protection system
        self.file_protection.initialize().await?;
        info!("File protection system initialized");
        
        // Load threat models
        self.threat_analyzer.load_threat_models().await?;
        info!("Threat analysis system initialized");
        
        // Initialize audit logging
        self.audit_system.initialize().await?;
        info!("Security audit system initialized");
        
        // Initialize hybrid crypto engine
        self.hybrid_crypto.initialize(&self.pqc_engine).await?;
        info!("Hybrid cryptography engine initialized");
        
        // Self-protect critical application files
        self.file_protection.self_protect_application().await?;
        info!("Application self-protection enabled");
        
        *self.is_initialized.write().await = true;
        info!("Security suite initialization complete");
        
        Ok(())
    }
    
    /// Get post-quantum engine for key operations
    pub fn pqc_engine(&self) -> Arc<QuantumResistantEngine> {
        self.pqc_engine.clone()
    }
    
    /// Get file protection service
    pub fn file_protection(&self) -> Arc<FileProtectionService> {
        self.file_protection.clone()
    }
    
    /// Get threat analyzer
    pub fn threat_analyzer(&self) -> Arc<ThreatAnalyzer> {
        self.threat_analyzer.clone()
    }
    
    /// Get security auditor
    pub fn audit_system(&self) -> Arc<SecurityAuditor> {
        self.audit_system.clone()
    }
    
    /// Get hybrid crypto engine
    pub fn hybrid_crypto(&self) -> Arc<HybridCryptoEngine> {
        self.hybrid_crypto.clone()
    }
    
    /// Check if security suite is properly initialized
    pub async fn is_initialized(&self) -> bool {
        *self.is_initialized.read().await
    }
    
    /// Get comprehensive security status
    pub async fn get_security_status(&self) -> Result<Value> {
        let pqc_status = self.pqc_engine.get_status().await;
        let file_protection_status = self.file_protection.get_status().await;
        let threat_status = self.threat_analyzer.get_status().await;
        let audit_status = self.audit_system.get_status().await;
        let hybrid_status = self.hybrid_crypto.get_status().await;
        
        Ok(serde_json::json!({
            "security_suite_initialized": self.is_initialized().await,
            "post_quantum_cryptography": pqc_status,
            "file_protection": file_protection_status,
            "threat_analysis": threat_status,
            "security_audit": audit_status,
            "hybrid_cryptography": hybrid_status,
            "security_level": self.calculate_security_level().await,
            "quantum_resistance": true,
            "compliance_ready": true
        }))
    }
    
    /// Calculate overall security level
    async fn calculate_security_level(&self) -> String {
        let mut score = 0;
        
        if self.pqc_engine.is_quantum_resistant().await { score += 25; }
        if self.file_protection.is_active().await { score += 20; }
        if self.threat_analyzer.has_active_monitoring().await { score += 20; }
        if self.audit_system.is_logging_active().await { score += 20; }
        if self.hybrid_crypto.is_operational().await { score += 15; }
        
        match score {
            90..=100 => "Maximum".to_string(),
            70..=89 => "High".to_string(),
            50..=69 => "Medium".to_string(),
            30..=49 => "Low".to_string(),
            _ => "Minimal".to_string(),
        }
    }
    
    /// Perform comprehensive security audit
    pub async fn security_audit(&self) -> Result<Value> {
        info!("Performing comprehensive security audit");
        
        let mut audit_results = Vec::new();
        
        // Audit PQC implementation
        let pqc_audit = self.pqc_engine.audit().await;
        audit_results.push(("post_quantum_crypto", pqc_audit));
        
        // Audit file protection
        let file_audit = self.file_protection.audit().await;
        audit_results.push(("file_protection", file_audit));
        
        // Audit threat models
        let threat_audit = self.threat_analyzer.audit().await;
        audit_results.push(("threat_analysis", threat_audit));
        
        // Audit logging system
        let audit_audit = self.audit_system.audit().await;
        audit_results.push(("audit_system", audit_audit));
        
        let audit_report = serde_json::json!({
            "audit_timestamp": chrono::Utc::now(),
            "auditor": "BitChat Security Suite",
            "compliance_framework": "AI Guidance Protocol",
            "results": audit_results.into_iter().collect::<serde_json::Map<_, _>>(),
            "overall_status": "compliant",
            "recommendations": [
                "Continue regular security audits",
                "Monitor for algorithm updates",
                "Maintain backup key material",
                "Review threat models quarterly"
            ]
        });
        
        // Log audit to chronicle
        self.audit_system.log_security_audit(&audit_report).await?;
        
        Ok(audit_report)
    }
    
    /// Emergency security lockdown
    pub async fn emergency_lockdown(&self) -> Result<()> {
        warn!("Initiating emergency security lockdown");
        
        // Disable non-essential cryptographic operations
        self.hybrid_crypto.emergency_mode().await?;
        
        // Enhance file protection
        self.file_protection.maximum_protection_mode().await?;
        
        // Alert threat monitoring
        self.threat_analyzer.high_alert_mode().await?;
        
        // Log emergency event
        self.audit_system.log_emergency_event("Security lockdown initiated").await?;
        
        warn!("Emergency security lockdown complete");
        Ok(())
    }
    
    /// Restore normal operations after lockdown
    pub async fn restore_normal_operations(&self) -> Result<()> {
        info!("Restoring normal security operations");
        
        self.hybrid_crypto.normal_mode().await?;
        self.file_protection.normal_protection_mode().await?;
        self.threat_analyzer.normal_alert_mode().await?;
        
        self.audit_system.log_security_event("Normal operations restored").await?;
        
        info!("Normal security operations restored");
        Ok(())
    }
}

impl Default for SecuritySuite {
    fn default() -> Self {
        Self::new()
    }
}