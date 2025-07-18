//! UI State Management Module
//! 
//! Manages application state and user preferences for the BitChat UI.

pub mod chat_state;
pub mod preferences;

pub use chat_state::ChatState;
pub use preferences::UserPreferences;

use anyhow::Result;
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Main application state manager
pub struct BitchatState {
    chat_state: Arc<RwLock<ChatState>>,
    preferences: Arc<RwLock<UserPreferences>>,
}

impl BitchatState {
    pub fn new() -> Self {
        Self {
            chat_state: Arc::new(RwLock::new(ChatState::new())),
            preferences: Arc::new(RwLock::new(UserPreferences::new())),
        }
    }
    
    /// Get current application state
    pub async fn get_current_state(&self) -> Value {
        let chat_state = self.chat_state.read().await;
        let preferences = self.preferences.read().await;
        
        serde_json::json!({
            "chat": chat_state.to_json(),
            "preferences": preferences.to_json(),
            "timestamp": chrono::Utc::now()
        })
    }
    
    /// Update user preferences
    pub async fn update_preferences(&self, new_preferences: Value) -> Result<String> {
        let mut preferences = self.preferences.write().await;
        preferences.update_from_json(new_preferences)?;
        Ok("Preferences updated successfully".to_string())
    }
    
    /// Update chat state
    pub async fn update_chat_state(&self, new_state: Value) -> Result<String> {
        let mut chat_state = self.chat_state.write().await;
        chat_state.update_from_json(new_state)?;
        Ok("Chat state updated successfully".to_string())
    }
}

impl Default for BitchatState {
    fn default() -> Self {
        Self::new()
    }
}