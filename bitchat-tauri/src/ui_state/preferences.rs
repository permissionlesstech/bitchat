//! User Preferences Management
//! 
//! Handles persistent user preferences and settings.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// User preferences and settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPreferences {
    pub nickname: String,
    pub auto_connect: bool,
    pub remember_channels: bool,
    pub save_message_history: bool,
    pub encryption_enabled: bool,
    pub enhanced_crypto_enabled: bool,
    pub discovery_enabled: bool,
    pub relay_messages: bool,
    pub battery_optimization: BatterySettings,
    pub privacy_settings: PrivacySettings,
    pub appearance: AppearanceSettings,
    pub keyboard_shortcuts: HashMap<String, String>,
    pub blocked_peers: Vec<String>,
    pub favorite_peers: Vec<String>,
    pub custom_channels: Vec<ChannelPreference>,
    pub backup_settings: BackupSettings,
}

/// Battery optimization settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatterySettings {
    pub enable_power_saving: bool,
    pub scan_interval_seconds: u64,
    pub connection_limit: u32,
    pub adaptive_scanning: bool,
    pub low_power_threshold: u8, // Battery percentage
}

/// Privacy and security settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacySettings {
    pub hide_real_name: bool,
    pub anonymous_mode: bool,
    pub rotate_peer_id: bool,
    pub rotation_interval_hours: u64,
    pub block_unknown_peers: bool,
    pub require_encryption: bool,
    pub verify_fingerprints: bool,
    pub emergency_wipe_enabled: bool,
    pub data_retention_days: u32,
}

/// Appearance and UI settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppearanceSettings {
    pub theme: String,
    pub font_family: String,
    pub font_size: u32,
    pub line_height: f32,
    pub message_spacing: u32,
    pub show_avatars: bool,
    pub show_timestamps: bool,
    pub timestamp_format: String,
    pub compact_mode: bool,
    pub auto_scroll: bool,
    pub highlight_mentions: bool,
    pub color_scheme: ColorScheme,
}

/// Custom color scheme
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColorScheme {
    pub primary_color: String,
    pub secondary_color: String,
    pub background_color: String,
    pub text_color: String,
    pub accent_color: String,
    pub error_color: String,
    pub success_color: String,
    pub warning_color: String,
}

/// Channel-specific preferences
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelPreference {
    pub name: String,
    pub auto_join: bool,
    pub notifications_enabled: bool,
    pub password: Option<String>, // Encrypted
    pub custom_color: Option<String>,
    pub priority: u8, // 0-10 for sorting
}

/// Backup and sync settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackupSettings {
    pub auto_backup: bool,
    pub backup_interval_hours: u64,
    pub backup_location: String,
    pub include_messages: bool,
    pub include_preferences: bool,
    pub include_peer_list: bool,
    pub encrypt_backups: bool,
    pub max_backup_files: u32,
}

impl UserPreferences {
    pub fn new() -> Self {
        Self {
            nickname: Self::generate_default_nickname(),
            auto_connect: true,
            remember_channels: true,
            save_message_history: true,
            encryption_enabled: true,
            enhanced_crypto_enabled: false,
            discovery_enabled: true,
            relay_messages: true,
            battery_optimization: BatterySettings::default(),
            privacy_settings: PrivacySettings::default(),
            appearance: AppearanceSettings::default(),
            keyboard_shortcuts: Self::default_keyboard_shortcuts(),
            blocked_peers: Vec::new(),
            favorite_peers: Vec::new(),
            custom_channels: Vec::new(),
            backup_settings: BackupSettings::default(),
        }
    }
    
    /// Generate a random default nickname
    fn generate_default_nickname() -> String {
        let adjectives = ["Quick", "Silent", "Bright", "Swift", "Clever", "Bold", "Wise", "Cool"];
        let nouns = ["Fox", "Wolf", "Eagle", "Shark", "Tiger", "Dragon", "Phoenix", "Falcon"];
        
        let adj = adjectives[rand::random::<usize>() % adjectives.len()];
        let noun = nouns[rand::random::<usize>() % nouns.len()];
        let num = rand::random::<u16>() % 1000;
        
        format!("{}{}{:03}", adj, noun, num)
    }
    
    /// Get default keyboard shortcuts
    fn default_keyboard_shortcuts() -> HashMap<String, String> {
        let mut shortcuts = HashMap::new();
        shortcuts.insert("send_message".to_string(), "Enter".to_string());
        shortcuts.insert("new_line".to_string(), "Shift+Enter".to_string());
        shortcuts.insert("toggle_sidebar".to_string(), "Ctrl+B".to_string());
        shortcuts.insert("search".to_string(), "Ctrl+F".to_string());
        shortcuts.insert("join_channel".to_string(), "Ctrl+J".to_string());
        shortcuts.insert("private_message".to_string(), "Ctrl+M".to_string());
        shortcuts.insert("clear_chat".to_string(), "Ctrl+L".to_string());
        shortcuts.insert("emergency_wipe".to_string(), "Ctrl+Alt+W".to_string());
        shortcuts
    }
    
    /// Set nickname
    pub fn set_nickname(&mut self, nickname: String) -> Result<()> {
        if nickname.trim().is_empty() {
            return Err(anyhow::anyhow!("Nickname cannot be empty"));
        }
        
        if nickname.len() > 50 {
            return Err(anyhow::anyhow!("Nickname too long (max 50 characters)"));
        }
        
        // Check for invalid characters
        if nickname.contains('@') || nickname.contains('#') || nickname.contains('/') {
            return Err(anyhow::anyhow!("Nickname contains invalid characters"));
        }
        
        self.nickname = nickname.trim().to_string();
        Ok(())
    }
    
    /// Add a peer to favorites
    pub fn add_favorite_peer(&mut self, peer_id: String) {
        if !self.favorite_peers.contains(&peer_id) {
            self.favorite_peers.push(peer_id);
        }
    }
    
    /// Remove a peer from favorites
    pub fn remove_favorite_peer(&mut self, peer_id: &str) {
        self.favorite_peers.retain(|p| p != peer_id);
    }
    
    /// Block a peer
    pub fn block_peer(&mut self, peer_id: String) {
        if !self.blocked_peers.contains(&peer_id) {
            self.blocked_peers.push(peer_id.clone());
        }
        
        // Remove from favorites if blocked
        self.remove_favorite_peer(&peer_id);
    }
    
    /// Unblock a peer
    pub fn unblock_peer(&mut self, peer_id: &str) {
        self.blocked_peers.retain(|p| p != peer_id);
    }
    
    /// Check if a peer is blocked
    pub fn is_peer_blocked(&self, peer_id: &str) -> bool {
        self.blocked_peers.contains(&peer_id.to_string())
    }
    
    /// Check if a peer is favorited
    pub fn is_peer_favorite(&self, peer_id: &str) -> bool {
        self.favorite_peers.contains(&peer_id.to_string())
    }
    
    /// Add or update channel preference
    pub fn set_channel_preference(&mut self, channel: ChannelPreference) {
        if let Some(existing) = self.custom_channels.iter_mut().find(|c| c.name == channel.name) {
            *existing = channel;
        } else {
            self.custom_channels.push(channel);
        }
    }
    
    /// Get channel preference
    pub fn get_channel_preference(&self, channel_name: &str) -> Option<&ChannelPreference> {
        self.custom_channels.iter().find(|c| c.name == channel_name)
    }
    
    /// Remove channel preference
    pub fn remove_channel_preference(&mut self, channel_name: &str) {
        self.custom_channels.retain(|c| c.name != channel_name);
    }
    
    /// Set keyboard shortcut
    pub fn set_keyboard_shortcut(&mut self, action: String, shortcut: String) {
        self.keyboard_shortcuts.insert(action, shortcut);
    }
    
    /// Get keyboard shortcut
    pub fn get_keyboard_shortcut(&self, action: &str) -> Option<&String> {
        self.keyboard_shortcuts.get(action)
    }
    
    /// Update theme
    pub fn set_theme(&mut self, theme: String) {
        self.appearance.theme = theme;
    }
    
    /// Update font settings
    pub fn set_font(&mut self, family: String, size: u32) {
        self.appearance.font_family = family;
        self.appearance.font_size = size.clamp(10, 24);
    }
    
    /// Enable/disable enhanced cryptography
    pub fn set_enhanced_crypto(&mut self, enabled: bool) {
        self.enhanced_crypto_enabled = enabled;
    }
    
    /// Update privacy settings
    pub fn update_privacy_settings(&mut self, settings: PrivacySettings) {
        self.privacy_settings = settings;
    }
    
    /// Update battery settings
    pub fn update_battery_settings(&mut self, settings: BatterySettings) {
        self.battery_optimization = settings;
    }
    
    /// Export preferences to JSON
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or_default()
    }
    
    /// Update preferences from JSON
    pub fn update_from_json(&mut self, json: Value) -> Result<()> {
        // Update nickname if provided
        if let Some(nickname) = json.get("nickname").and_then(|v| v.as_str()) {
            self.set_nickname(nickname.to_string())?;
        }
        
        // Update boolean settings
        if let Some(auto_connect) = json.get("auto_connect").and_then(|v| v.as_bool()) {
            self.auto_connect = auto_connect;
        }
        
        if let Some(remember_channels) = json.get("remember_channels").and_then(|v| v.as_bool()) {
            self.remember_channels = remember_channels;
        }
        
        if let Some(save_history) = json.get("save_message_history").and_then(|v| v.as_bool()) {
            self.save_message_history = save_history;
        }
        
        if let Some(encryption) = json.get("encryption_enabled").and_then(|v| v.as_bool()) {
            self.encryption_enabled = encryption;
        }
        
        if let Some(enhanced_crypto) = json.get("enhanced_crypto_enabled").and_then(|v| v.as_bool()) {
            self.enhanced_crypto_enabled = enhanced_crypto;
        }
        
        if let Some(discovery) = json.get("discovery_enabled").and_then(|v| v.as_bool()) {
            self.discovery_enabled = discovery;
        }
        
        if let Some(relay) = json.get("relay_messages").and_then(|v| v.as_bool()) {
            self.relay_messages = relay;
        }
        
        // Update appearance settings
        if let Some(appearance) = json.get("appearance") {
            if let Some(theme) = appearance.get("theme").and_then(|v| v.as_str()) {
                self.appearance.theme = theme.to_string();
            }
            
            if let Some(font_family) = appearance.get("font_family").and_then(|v| v.as_str()) {
                self.appearance.font_family = font_family.to_string();
            }
            
            if let Some(font_size) = appearance.get("font_size").and_then(|v| v.as_u64()) {
                self.appearance.font_size = (font_size as u32).clamp(10, 24);
            }
        }
        
        Ok(())
    }
    
    /// Reset to default preferences
    pub fn reset_to_defaults(&mut self) {
        let nickname = self.nickname.clone(); // Preserve nickname
        *self = Self::new();
        self.nickname = nickname;
    }
    
    /// Validate preferences
    pub fn validate(&self) -> Result<()> {
        if self.nickname.trim().is_empty() {
            return Err(anyhow::anyhow!("Nickname cannot be empty"));
        }
        
        if self.battery_optimization.scan_interval_seconds == 0 {
            return Err(anyhow::anyhow!("Scan interval must be greater than 0"));
        }
        
        if self.privacy_settings.data_retention_days == 0 {
            return Err(anyhow::anyhow!("Data retention must be at least 1 day"));
        }
        
        Ok(())
    }
    
    /// Get security level assessment
    pub fn get_security_level(&self) -> String {
        let mut score = 0;
        
        if self.encryption_enabled { score += 20; }
        if self.enhanced_crypto_enabled { score += 20; }
        if self.privacy_settings.require_encryption { score += 15; }
        if self.privacy_settings.verify_fingerprints { score += 15; }
        if self.privacy_settings.rotate_peer_id { score += 10; }
        if self.privacy_settings.block_unknown_peers { score += 10; }
        if self.privacy_settings.emergency_wipe_enabled { score += 10; }
        
        match score {
            90..=100 => "Maximum".to_string(),
            70..=89 => "High".to_string(),
            50..=69 => "Medium".to_string(),
            30..=49 => "Low".to_string(),
            _ => "Minimal".to_string(),
        }
    }
}

impl Default for BatterySettings {
    fn default() -> Self {
        Self {
            enable_power_saving: true,
            scan_interval_seconds: 5,
            connection_limit: 8,
            adaptive_scanning: true,
            low_power_threshold: 20,
        }
    }
}

impl Default for PrivacySettings {
    fn default() -> Self {
        Self {
            hide_real_name: true,
            anonymous_mode: false,
            rotate_peer_id: true,
            rotation_interval_hours: 24,
            block_unknown_peers: false,
            require_encryption: true,
            verify_fingerprints: false,
            emergency_wipe_enabled: true,
            data_retention_days: 30,
        }
    }
}

impl Default for AppearanceSettings {
    fn default() -> Self {
        Self {
            theme: "dark".to_string(),
            font_family: "monospace".to_string(),
            font_size: 14,
            line_height: 1.4,
            message_spacing: 8,
            show_avatars: true,
            show_timestamps: true,
            timestamp_format: "HH:mm:ss".to_string(),
            compact_mode: false,
            auto_scroll: true,
            highlight_mentions: true,
            color_scheme: ColorScheme::default(),
        }
    }
}

impl Default for ColorScheme {
    fn default() -> Self {
        Self {
            primary_color: "#00ff41".to_string(),    // Matrix green
            secondary_color: "#008f11".to_string(),   // Darker green
            background_color: "#0d1117".to_string(),  // Dark background
            text_color: "#c9d1d9".to_string(),        // Light text
            accent_color: "#58a6ff".to_string(),      // Blue accent
            error_color: "#ff6b6b".to_string(),       // Red
            success_color: "#51cf66".to_string(),     // Green
            warning_color: "#ffd43b".to_string(),     // Yellow
        }
    }
}

impl Default for BackupSettings {
    fn default() -> Self {
        Self {
            auto_backup: false,
            backup_interval_hours: 24,
            backup_location: "~/Documents/BitChat/Backups".to_string(),
            include_messages: true,
            include_preferences: true,
            include_peer_list: true,
            encrypt_backups: true,
            max_backup_files: 10,
        }
    }
}

impl Default for UserPreferences {
    fn default() -> Self {
        Self::new()
    }
}