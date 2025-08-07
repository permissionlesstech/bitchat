#!/usr/bin/env python3
"""
Script to help organize files for BitChat Meshtastic integration PR
Run this in your local BitChat repository after downloading files from Replit
"""

import os
import shutil
from pathlib import Path

def create_pr_structure():
    """Create the proper directory structure and move files"""
    
    # Files to copy and their destinations
    file_mapping = {
        # Python backend files -> meshtastic/
        'bitchat_meshtastic_types.py': 'meshtastic/',
        'meshtastic_bridge.py': 'meshtastic/',
        'meshtastic_config.py': 'meshtastic/',
        'protocol_translator.py': 'meshtastic/',
        'requirements_meshtastic.txt': 'meshtastic/',
        'install_meshtastic.sh': 'meshtastic/',
        
        # Swift files -> bitchat/
        'MeshtasticBridge.swift': 'bitchat/',
        'MeshtasticFallbackManager.swift': 'bitchat/',
        'NetworkAvailabilityDetector.swift': 'bitchat/',
        'MeshtasticSettingsView.swift': 'bitchat/',
        
        # Testing files -> tests/
        'test_meshtastic_integration.py': 'tests/',
        'simple_test.py': 'tests/',
        'TESTING_GUIDE.md': 'tests/',
        
        # Documentation -> docs/
        'PULL_REQUEST.md': 'docs/',
        'PR_FILE_STRUCTURE.md': 'docs/',
        'DOWNLOAD_GUIDE.md': 'docs/'
    }
    
    print("🚀 Setting up BitChat Meshtastic integration files...")
    print("=" * 50)
    
    # Create directories
    directories = ['meshtastic', 'tests', 'docs']
    for directory in directories:
        Path(directory).mkdir(exist_ok=True)
        print(f"✓ Created directory: {directory}/")
    
    # Copy files
    for source_file, dest_dir in file_mapping.items():
        if os.path.exists(source_file):
            dest_path = os.path.join(dest_dir, source_file)
            shutil.copy2(source_file, dest_path)
            print(f"✓ Copied: {source_file} -> {dest_path}")
        else:
            print(f"⚠ Missing: {source_file} (download from Replit)")
    
    # Make install script executable
    install_script = 'meshtastic/install_meshtastic.sh'
    if os.path.exists(install_script):
        os.chmod(install_script, 0o755)
        print(f"✓ Made executable: {install_script}")
    
    print("\n📋 Next steps:")
    print("1. git checkout -b feature/meshtastic-integration")
    print("2. git add meshtastic/ tests/ docs/ bitchat/Meshtastic*.swift bitchat/NetworkAvailabilityDetector.swift")
    print("3. git commit -m 'Add Meshtastic LoRa mesh integration'")
    print("4. git push origin feature/meshtastic-integration")
    print("5. Create pull request on GitHub")
    
    print(f"\n✅ Setup complete! {len([f for f in file_mapping.keys() if os.path.exists(f)])} files ready for PR")

if __name__ == "__main__":
    create_pr_structure()