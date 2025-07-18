//! Threat Analysis Engine
//! 
//! Integrates Overlord threat modeling and STRIDE framework.

use anyhow::{Result, Context};
use log::{info, debug, warn};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Threat analysis engine
pub struct ThreatAnalyzer {
    threat_models: Arc<RwLock<HashMap<String, ThreatModel>>>,
    active_threats: Arc<RwLock<Vec<ThreatIncident>>>,
    monitoring_active: Arc<RwLock<bool>>,
    alert_level: Arc<RwLock<AlertLevel>>,
    is_initialized: Arc<RwLock<bool>>,
}

/// STRIDE threat categories
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StrideCategory {
    Spoofing,           // Identity spoofing attacks
    Tampering,          // Data tampering attacks
    Repudiation,        // Non-repudiation attacks
    InformationDisclosure, // Information disclosure attacks
    DenialOfService,    // Denial of service attacks
    ElevationOfPrivilege, // Privilege escalation attacks
}

/// Threat model definition
#[derive(Debug, Clone)]
pub struct ThreatModel {
    pub id: String,
    pub name: String,
    pub category: StrideCategory,
    pub severity: ThreatSeverity,
    pub description: String,
    pub mitigation_strategies: Vec<String>,
    pub indicators: Vec<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// Threat severity levels
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum ThreatSeverity {
    Low,
    Medium,
    High,
    Critical,
}

/// Threat incident
#[derive(Debug, Clone)]
pub struct ThreatIncident {
    pub id: String,
    pub threat_model_id: String,
    pub category: StrideCategory,
    pub severity: ThreatSeverity,
    pub description: String,
    pub indicators_matched: Vec<String>,
    pub detected_at: chrono::DateTime<chrono::Utc>,
    pub status: IncidentStatus,
}

/// Incident status
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IncidentStatus {
    Detected,
    Investigating,
    Mitigated,
    Resolved,
    FalsePositive,
}

/// Alert levels
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AlertLevel {
    Normal,
    Elevated,
    High,
    Emergency,
}

impl ThreatAnalyzer {
    pub fn new() -> Self {
        Self {
            threat_models: Arc::new(RwLock::new(HashMap::new())),
            active_threats: Arc::new(RwLock::new(Vec::new())),
            monitoring_active: Arc::new(RwLock::new(false)),
            alert_level: Arc::new(RwLock::new(AlertLevel::Normal)),
            is_initialized: Arc::new(RwLock::new(false)),
        }
    }
    
    /// Load threat models from Overlord framework
    pub async fn load_threat_models(&self) -> Result<()> {
        info!("Loading threat models from Overlord framework");
        
        let mut models = self.threat_models.write().await;
        
        // Load predefined STRIDE-based threat models
        let threat_models = vec![
            ThreatModel {
                id: "bluetooth_spoofing".to_string(),
                name: "Bluetooth Device Spoofing".to_string(),
                category: StrideCategory::Spoofing,
                severity: ThreatSeverity::High,
                description: "Attacker impersonates legitimate Bluetooth device".to_string(),
                mitigation_strategies: vec![
                    "Device authentication".to_string(),
                    "MAC address validation".to_string(),
                    "Connection history verification".to_string(),
                ],
                indicators: vec![
                    "Duplicate device names".to_string(),
                    "Unexpected connection attempts".to_string(),
                    "MAC address anomalies".to_string(),
                ],
                created_at: chrono::Utc::now(),
            },
            ThreatModel {
                id: "message_tampering".to_string(),
                name: "Message Tampering".to_string(),
                category: StrideCategory::Tampering,
                severity: ThreatSeverity::Critical,
                description: "Unauthorized modification of messages in transit".to_string(),
                mitigation_strategies: vec![
                    "End-to-end encryption".to_string(),
                    "Message authentication codes".to_string(),
                    "Digital signatures".to_string(),
                ],
                indicators: vec![
                    "Checksum mismatches".to_string(),
                    "Signature verification failures".to_string(),
                    "Unexpected message modifications".to_string(),
                ],
                created_at: chrono::Utc::now(),
            },
            ThreatModel {
                id: "eavesdropping".to_string(),
                name: "Communication Eavesdropping".to_string(),
                category: StrideCategory::InformationDisclosure,
                severity: ThreatSeverity::High,
                description: "Unauthorized interception of communications".to_string(),
                mitigation_strategies: vec![
                    "Strong encryption".to_string(),
                    "Perfect forward secrecy".to_string(),
                    "Quantum-resistant algorithms".to_string(),
                ],
                indicators: vec![
                    "Unusual network traffic patterns".to_string(),
                    "Unexpected device discoveries".to_string(),
                    "Signal strength anomalies".to_string(),
                ],
                created_at: chrono::Utc::now(),
            },
            ThreatModel {
                id: "bluetooth_jamming".to_string(),
                name: "Bluetooth Signal Jamming".to_string(),
                category: StrideCategory::DenialOfService,
                severity: ThreatSeverity::Medium,
                description: "Intentional interference with Bluetooth communications".to_string(),
                mitigation_strategies: vec![
                    "Frequency hopping".to_string(),
                    "Alternative communication channels".to_string(),
                    "Mesh network redundancy".to_string(),
                ],
                indicators: vec![
                    "High packet loss rates".to_string(),
                    "Connection timeouts".to_string(),
                    "Signal interference patterns".to_string(),
                ],
                created_at: chrono::Utc::now(),
            },
            ThreatModel {
                id: "key_compromise".to_string(),
                name: "Cryptographic Key Compromise".to_string(),
                category: StrideCategory::ElevationOfPrivilege,
                severity: ThreatSeverity::Critical,
                description: "Unauthorized access to encryption keys".to_string(),
                mitigation_strategies: vec![
                    "Key rotation".to_string(),
                    "Hardware security modules".to_string(),
                    "Key derivation functions".to_string(),
                ],
                indicators: vec![
                    "Unexpected decryption attempts".to_string(),
                    "Key usage anomalies".to_string(),
                    "Unauthorized key access".to_string(),
                ],
                created_at: chrono::Utc::now(),
            },
        ];
        
        for model in threat_models {
            models.insert(model.id.clone(), model);
        }
        
        *self.monitoring_active.write().await = true;
        *self.is_initialized.write().await = true;
        
        info!("Loaded {} threat models", models.len());
        Ok(())
    }
    
    /// Analyze potential threat based on indicators
    pub async fn analyze_threat(&self, indicators: &[String]) -> Result<Option<ThreatIncident>> {
        if !*self.monitoring_active.read().await {
            return Ok(None);
        }
        
        debug!("Analyzing threat indicators: {:?}", indicators);
        
        let models = self.threat_models.read().await;
        
        // Check indicators against threat models
        for model in models.values() {
            let matched_indicators: Vec<String> = indicators.iter()
                .filter(|indicator| {
                    model.indicators.iter().any(|model_indicator| {
                        indicator.to_lowercase().contains(&model_indicator.to_lowercase())
                    })
                })
                .cloned()
                .collect();
            
            if !matched_indicators.is_empty() {
                let incident = ThreatIncident {
                    id: uuid::Uuid::new_v4().to_string(),
                    threat_model_id: model.id.clone(),
                    category: model.category.clone(),
                    severity: model.severity.clone(),
                    description: format!("Detected: {}", model.description),
                    indicators_matched: matched_indicators,
                    detected_at: chrono::Utc::now(),
                    status: IncidentStatus::Detected,
                };
                
                warn!("Threat detected: {} (severity: {:?})", model.name, model.severity);
                
                // Store incident
                self.active_threats.write().await.push(incident.clone());
                
                // Escalate alert level if necessary
                self.escalate_alert_level(&model.severity).await;
                
                return Ok(Some(incident));
            }
        }
        
        Ok(None)
    }
    
    /// Escalate alert level based on threat severity
    async fn escalate_alert_level(&self, severity: &ThreatSeverity) {
        let mut alert_level = self.alert_level.write().await;
        
        let new_level = match severity {
            ThreatSeverity::Critical => AlertLevel::Emergency,
            ThreatSeverity::High => AlertLevel::High,
            ThreatSeverity::Medium => AlertLevel::Elevated,
            ThreatSeverity::Low => AlertLevel::Normal,
        };
        
        if new_level != *alert_level {
            *alert_level = new_level;
            info!("Alert level escalated to: {:?}", *alert_level);
        }
    }
    
    /// Check if monitoring is active
    pub async fn has_active_monitoring(&self) -> bool {
        *self.monitoring_active.read().await
    }
    
    /// Set high alert mode
    pub async fn high_alert_mode(&self) -> Result<()> {
        info!("Activating high alert mode");
        *self.alert_level.write().await = AlertLevel::Emergency;
        *self.monitoring_active.write().await = true;
        Ok(())
    }
    
    /// Set normal alert mode
    pub async fn normal_alert_mode(&self) -> Result<()> {
        info!("Restoring normal alert mode");
        *self.alert_level.write().await = AlertLevel::Normal;
        Ok(())
    }
    
    /// Get threat analysis status
    pub async fn get_status(&self) -> Value {
        let models = self.threat_models.read().await;
        let threats = self.active_threats.read().await;
        let alert_level = self.alert_level.read().await;
        
        let active_critical = threats.iter()
            .filter(|t| t.severity == ThreatSeverity::Critical && t.status == IncidentStatus::Detected)
            .count();
        
        let active_high = threats.iter()
            .filter(|t| t.severity == ThreatSeverity::High && t.status == IncidentStatus::Detected)
            .count();
        
        serde_json::json!({
            "initialized": *self.is_initialized.read().await,
            "monitoring_active": *self.monitoring_active.read().await,
            "alert_level": format!("{:?}", *alert_level),
            "threat_models_loaded": models.len(),
            "active_incidents": threats.len(),
            "critical_threats": active_critical,
            "high_threats": active_high,
            "stride_categories_covered": 6
        })
    }
    
    /// Perform threat analysis audit
    pub async fn audit(&self) -> Value {
        let models = self.threat_models.read().await;
        let threats = self.active_threats.read().await;
        
        let mut model_audits = Vec::new();
        for model in models.values() {
            model_audits.push(serde_json::json!({
                "id": model.id,
                "name": model.name,
                "category": format!("{:?}", model.category),
                "severity": format!("{:?}", model.severity),
                "mitigation_strategies": model.mitigation_strategies.len(),
                "indicators": model.indicators.len()
            }));
        }
        
        let mut incident_summary = HashMap::new();
        for threat in threats.iter() {
            *incident_summary.entry(format!("{:?}", threat.severity)).or_insert(0) += 1;
        }
        
        serde_json::json!({
            "audit_type": "threat_analysis",
            "status": "active",
            "threat_models": model_audits,
            "incident_summary": incident_summary,
            "stride_coverage": {
                "spoofing": true,
                "tampering": true,
                "repudiation": false,
                "information_disclosure": true,
                "denial_of_service": true,
                "elevation_of_privilege": true
            },
            "recommendations": [
                "Implement repudiation threat models",
                "Regular threat model reviews",
                "Incident response procedures",
                "Threat intelligence integration"
            ]
        })
    }
    
    /// Get active threats
    pub async fn get_active_threats(&self) -> Vec<ThreatIncident> {
        self.active_threats.read().await
            .iter()
            .filter(|t| matches!(t.status, IncidentStatus::Detected | IncidentStatus::Investigating))
            .cloned()
            .collect()
    }
    
    /// Update incident status
    pub async fn update_incident_status(&self, incident_id: &str, status: IncidentStatus) -> Result<()> {
        let mut threats = self.active_threats.write().await;
        
        if let Some(incident) = threats.iter_mut().find(|t| t.id == incident_id) {
            incident.status = status;
            info!("Updated incident {} status to {:?}", incident_id, incident.status);
        } else {
            return Err(anyhow::anyhow!("Incident not found: {}", incident_id));
        }
        
        Ok(())
    }
}

impl Default for ThreatAnalyzer {
    fn default() -> Self {
        Self::new()
    }
}