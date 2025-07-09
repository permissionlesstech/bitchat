"""
Meshtastic Configuration Management

Handles device detection, connection preferences, and user consent
for BitChat's Meshtastic integration.
"""

import json
import time
from typing import Dict, Any, List, Optional
from pathlib import Path

from clean_bitchat_meshtastic_types import MeshtasticDeviceInfo


class MeshtasticConfig:
    """Manages Meshtastic device configuration and preferences"""
    
    def __init__(self, config_path: str = "meshtastic_config.json"):
        self.config_path = config_path
        self.config = self._load_config()
    
    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from file"""
        try:
            if Path(self.config_path).exists():
                with open(self.config_path, 'r') as f:
                    return json.load(f)
        except Exception:
            pass
        
        # Default configuration
        return {
            "enabled": False,
            "user_consent": False,
            "auto_fallback": True,
            "fallback_threshold_seconds": 30,
            "preferred_device_id": None,
            "known_devices": [],
            "last_scan_timestamp": 0,
            "scan_timeout_seconds": 30,
            "connection_timeout_seconds": 10,
            "retry_attempts": 3,
            "version": "1.0"
        }
    
    def save_config(self):
        """Save current configuration to file"""
        try:
            with open(self.config_path, 'w') as f:
                json.dump(self.config, f, indent=2)
        except Exception as e:
            print(f"Failed to save config: {e}")
    
    def set_user_consent(self, consented: bool):
        """Set user consent for Meshtastic integration"""
        self.config["user_consent"] = consented
        self.config["enabled"] = consented  # Enable when user consents
        self.save_config()
    
    def get_user_consent(self) -> bool:
        """Check if user has consented to Meshtastic integration"""
        return self.config.get("user_consent", False)
    
    def is_enabled(self) -> bool:
        """Check if Meshtastic integration is enabled"""
        return self.config.get("enabled", False) and self.get_user_consent()
    
    def should_auto_fallback(self) -> bool:
        """Check if auto-fallback is enabled"""
        return self.config.get("auto_fallback", True) and self.is_enabled()
    
    def get_fallback_threshold(self) -> int:
        """Get time threshold for BLE fallback in seconds"""
        return self.config.get("fallback_threshold_seconds", 30)
    
    def add_known_device(self, device: MeshtasticDeviceInfo):
        """Add a device to known devices list"""
        devices = self.get_known_devices()
        
        # Update if exists, add if new
        found = False
        for i, existing in enumerate(devices):
            if existing.device_id == device.device_id:
                devices[i] = device
                found = True
                break
        
        if not found:
            devices.append(device)
        
        # Store as dictionaries
        self.config["known_devices"] = [d.to_dict() for d in devices]
        self.save_config()
    
    def get_known_devices(self) -> List[MeshtasticDeviceInfo]:
        """Get list of known Meshtastic devices"""
        devices = []
        for device_data in self.config.get("known_devices", []):
            try:
                device = MeshtasticDeviceInfo.from_dict(device_data)
                devices.append(device)
            except Exception:
                continue  # Skip invalid device entries
        return devices
    
    def set_preferred_device(self, device_id: str):
        """Set preferred Meshtastic device"""
        self.config["preferred_device_id"] = device_id
        self.save_config()
    
    def get_preferred_device(self) -> Optional[str]:
        """Get preferred device ID"""
        return self.config.get("preferred_device_id")
    
    def update_scan_timestamp(self):
        """Update last scan timestamp"""
        self.config["last_scan_timestamp"] = int(time.time())
        self.save_config()
    
    def should_rescan(self, max_age: int = 300) -> bool:
        """Check if devices should be rescanned (default 5 minutes)"""
        last_scan = self.config.get("last_scan_timestamp", 0)
        return (time.time() - last_scan) > max_age
    
    def get_scan_timeout(self) -> int:
        """Get device scan timeout in seconds"""
        return self.config.get("scan_timeout_seconds", 30)
    
    def get_connection_timeout(self) -> int:
        """Get connection timeout in seconds"""
        return self.config.get("connection_timeout_seconds", 10)
    
    def get_retry_attempts(self) -> int:
        """Get number of retry attempts for failed connections"""
        return self.config.get("retry_attempts", 3)
    
    def export_settings(self) -> Dict[str, Any]:
        """Export settings for sharing with Swift app"""
        return {
            "enabled": self.is_enabled(),
            "user_consent": self.get_user_consent(),
            "auto_fallback": self.should_auto_fallback(),
            "fallback_threshold": self.get_fallback_threshold(),
            "preferred_device": self.get_preferred_device(),
            "known_devices": [d.to_dict() for d in self.get_known_devices()],
            "scan_timeout": self.get_scan_timeout(),
            "connection_timeout": self.get_connection_timeout(),
            "retry_attempts": self.get_retry_attempts()
        }
    
    def update_settings(self, settings: Dict[str, Any]):
        """Update settings from Swift app"""
        if "user_consent" in settings:
            self.set_user_consent(settings["user_consent"])
        
        if "auto_fallback" in settings:
            self.config["auto_fallback"] = settings["auto_fallback"]
        
        if "fallback_threshold" in settings:
            self.config["fallback_threshold_seconds"] = settings["fallback_threshold"]
        
        if "preferred_device" in settings:
            self.config["preferred_device_id"] = settings["preferred_device"]
        
        if "scan_timeout" in settings:
            self.config["scan_timeout_seconds"] = settings["scan_timeout"]
        
        if "connection_timeout" in settings:
            self.config["connection_timeout_seconds"] = settings["connection_timeout"]
        
        if "retry_attempts" in settings:
            self.config["retry_attempts"] = settings["retry_attempts"]
        
        self.save_config()