//! Chat State Management
//! 
//! Manages the current state of the chat interface.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Current state of the chat interface
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatState {
    pub current_channel: Option<String>,
    pub active_private_chats: Vec<String>,
    pub unread_counts: HashMap<String, u32>,
    pub typing_indicators: HashMap<String, Vec<String>>, // channel -> users typing
    pub last_seen_messages: HashMap<String, String>, // channel -> last message ID
    pub sidebar_open: bool,
    pub channel_list_open: bool,
    pub peer_list_open: bool,
    pub search_query: String,
    pub search_results: Vec<String>,
    pub notification_settings: NotificationSettings,
    pub ui_theme: String,
    pub font_size: u32,
    pub auto_scroll: bool,
    pub show_timestamps: bool,
    pub show_avatars: bool,
    pub compact_mode: bool,
}

/// Notification settings for the chat
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationSettings {
    pub enable_sounds: bool,
    pub enable_desktop_notifications: bool,
    pub mention_notifications: bool,
    pub private_message_notifications: bool,
    pub channel_notifications: HashMap<String, bool>, // per-channel notification settings
    pub quiet_hours_start: Option<String>, // HH:MM format
    pub quiet_hours_end: Option<String>,   // HH:MM format
}

impl ChatState {
    pub fn new() -> Self {
        Self {
            current_channel: None,
            active_private_chats: Vec::new(),
            unread_counts: HashMap::new(),
            typing_indicators: HashMap::new(),
            last_seen_messages: HashMap::new(),
            sidebar_open: false,
            channel_list_open: false,
            peer_list_open: false,
            search_query: String::new(),
            search_results: Vec::new(),
            notification_settings: NotificationSettings::default(),
            ui_theme: "dark".to_string(),
            font_size: 14,
            auto_scroll: true,
            show_timestamps: true,
            show_avatars: true,
            compact_mode: false,
        }
    }
    
    /// Switch to a channel
    pub fn switch_to_channel(&mut self, channel: String) {
        self.current_channel = Some(channel.clone());
        
        // Mark messages as read
        self.unread_counts.insert(channel, 0);
    }
    
    /// Switch to public chat
    pub fn switch_to_public(&mut self) {
        self.current_channel = None;
        self.unread_counts.insert("public".to_string(), 0);
    }
    
    /// Add unread message to a channel
    pub fn add_unread(&mut self, channel: &str) {
        let count = self.unread_counts.get(channel).unwrap_or(&0);
        self.unread_counts.insert(channel.to_string(), count + 1);
    }
    
    /// Clear unread count for a channel
    pub fn clear_unread(&mut self, channel: &str) {
        self.unread_counts.insert(channel.to_string(), 0);
    }
    
    /// Get total unread count
    pub fn get_total_unread(&self) -> u32 {
        self.unread_counts.values().sum()
    }
    
    /// Add user to typing indicators
    pub fn add_typing_user(&mut self, channel: &str, user: &str) {
        let users = self.typing_indicators.entry(channel.to_string()).or_insert_with(Vec::new);
        
        if !users.contains(&user.to_string()) {
            users.push(user.to_string());
        }
    }
    
    /// Remove user from typing indicators
    pub fn remove_typing_user(&mut self, channel: &str, user: &str) {
        if let Some(users) = self.typing_indicators.get_mut(channel) {
            users.retain(|u| u != user);
            
            if users.is_empty() {
                self.typing_indicators.remove(channel);
            }
        }
    }
    
    /// Get typing users for a channel
    pub fn get_typing_users(&self, channel: &str) -> Vec<String> {
        self.typing_indicators.get(channel).cloned().unwrap_or_default()
    }
    
    /// Toggle sidebar
    pub fn toggle_sidebar(&mut self) {
        self.sidebar_open = !self.sidebar_open;
    }
    
    /// Toggle channel list
    pub fn toggle_channel_list(&mut self) {
        self.channel_list_open = !self.channel_list_open;
    }
    
    /// Toggle peer list
    pub fn toggle_peer_list(&mut self) {
        self.peer_list_open = !self.peer_list_open;
    }
    
    /// Set search query
    pub fn set_search_query(&mut self, query: String) {
        self.search_query = query;
    }
    
    /// Set search results
    pub fn set_search_results(&mut self, results: Vec<String>) {
        self.search_results = results;
    }
    
    /// Clear search
    pub fn clear_search(&mut self) {
        self.search_query.clear();
        self.search_results.clear();
    }
    
    /// Update last seen message for a channel
    pub fn update_last_seen(&mut self, channel: &str, message_id: &str) {
        self.last_seen_messages.insert(channel.to_string(), message_id.to_string());
    }
    
    /// Get last seen message ID for a channel
    pub fn get_last_seen(&self, channel: &str) -> Option<&String> {
        self.last_seen_messages.get(channel)
    }
    
    /// Set UI theme
    pub fn set_theme(&mut self, theme: String) {
        self.ui_theme = theme;
    }
    
    /// Set font size
    pub fn set_font_size(&mut self, size: u32) {
        self.font_size = size.clamp(10, 24); // Reasonable bounds
    }
    
    /// Toggle auto scroll
    pub fn toggle_auto_scroll(&mut self) {
        self.auto_scroll = !self.auto_scroll;
    }
    
    /// Toggle timestamps
    pub fn toggle_timestamps(&mut self) {
        self.show_timestamps = !self.show_timestamps;
    }
    
    /// Toggle avatars
    pub fn toggle_avatars(&mut self) {
        self.show_avatars = !self.show_avatars;
    }
    
    /// Toggle compact mode
    pub fn toggle_compact_mode(&mut self) {
        self.compact_mode = !self.compact_mode;
    }
    
    /// Export state to JSON
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or_default()
    }
    
    /// Update state from JSON
    pub fn update_from_json(&mut self, json: Value) -> Result<()> {
        if let Some(current_channel) = json.get("current_channel").and_then(|v| v.as_str()) {
            self.current_channel = Some(current_channel.to_string());
        }
        
        if let Some(sidebar_open) = json.get("sidebar_open").and_then(|v| v.as_bool()) {
            self.sidebar_open = sidebar_open;
        }
        
        if let Some(channel_list_open) = json.get("channel_list_open").and_then(|v| v.as_bool()) {
            self.channel_list_open = channel_list_open;
        }
        
        if let Some(peer_list_open) = json.get("peer_list_open").and_then(|v| v.as_bool()) {
            self.peer_list_open = peer_list_open;
        }
        
        if let Some(search_query) = json.get("search_query").and_then(|v| v.as_str()) {
            self.search_query = search_query.to_string();
        }
        
        if let Some(theme) = json.get("ui_theme").and_then(|v| v.as_str()) {
            self.ui_theme = theme.to_string();
        }
        
        if let Some(font_size) = json.get("font_size").and_then(|v| v.as_u64()) {
            self.font_size = font_size as u32;
        }
        
        if let Some(auto_scroll) = json.get("auto_scroll").and_then(|v| v.as_bool()) {
            self.auto_scroll = auto_scroll;
        }
        
        if let Some(show_timestamps) = json.get("show_timestamps").and_then(|v| v.as_bool()) {
            self.show_timestamps = show_timestamps;
        }
        
        if let Some(show_avatars) = json.get("show_avatars").and_then(|v| v.as_bool()) {
            self.show_avatars = show_avatars;
        }
        
        if let Some(compact_mode) = json.get("compact_mode").and_then(|v| v.as_bool()) {
            self.compact_mode = compact_mode;
        }
        
        Ok(())
    }
    
    /// Reset to default state
    pub fn reset(&mut self) {
        *self = Self::new();
    }
    
    /// Get display info for current view
    pub fn get_current_view_info(&self) -> Value {
        serde_json::json!({
            "type": if self.current_channel.is_some() { "channel" } else { "public" },
            "name": self.current_channel.as_ref().unwrap_or(&"Public".to_string()),
            "unread_count": self.unread_counts.get(
                self.current_channel.as_ref().unwrap_or(&"public".to_string())
            ).unwrap_or(&0),
            "typing_users": self.get_typing_users(
                self.current_channel.as_ref().unwrap_or(&"public".to_string())
            )
        })
    }
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            enable_sounds: true,
            enable_desktop_notifications: true,
            mention_notifications: true,
            private_message_notifications: true,
            channel_notifications: HashMap::new(),
            quiet_hours_start: None,
            quiet_hours_end: None,
        }
    }
}

impl NotificationSettings {
    /// Check if notifications should be shown for a channel
    pub fn should_notify_for_channel(&self, channel: &str) -> bool {
        self.channel_notifications.get(channel).copied().unwrap_or(true)
    }
    
    /// Set notification setting for a channel
    pub fn set_channel_notification(&mut self, channel: String, enabled: bool) {
        self.channel_notifications.insert(channel, enabled);
    }
    
    /// Check if we're in quiet hours
    pub fn is_quiet_hours(&self) -> bool {
        if let (Some(start), Some(end)) = (&self.quiet_hours_start, &self.quiet_hours_end) {
            let now = chrono::Local::now().time();
            
            if let (Ok(start_time), Ok(end_time)) = (
                chrono::NaiveTime::parse_from_str(start, "%H:%M"),
                chrono::NaiveTime::parse_from_str(end, "%H:%M")
            ) {
                if start_time <= end_time {
                    // Same day (e.g., 09:00 to 17:00)
                    now >= start_time && now <= end_time
                } else {
                    // Crosses midnight (e.g., 22:00 to 08:00)
                    now >= start_time || now <= end_time
                }
            } else {
                false
            }
        } else {
            false
        }
    }
}

impl Default for ChatState {
    fn default() -> Self {
        Self::new()
    }
}