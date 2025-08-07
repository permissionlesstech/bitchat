#!/bin/bash
# BitChat Meshtastic Integration Setup Script

echo "Setting up BitChat Meshtastic integration..."

# Check Python version
python_version=$(python3 -c "import sys; print('.'.join(map(str, sys.version_info[:2])))")
echo "Python version: $python_version"

if [[ "$(printf '%s\n' "3.7" "$python_version" | sort -V | head -n1)" != "3.7" ]]; then
    echo "Error: Python 3.7 or higher required"
    exit 1
fi

# Install Python dependencies
echo "Installing Python dependencies..."
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt

# Verify installation
echo "Verifying Meshtastic installation..."
python3 -c "import meshtastic; print('Meshtastic version:', meshtastic.__version__)" || {
    echo "Error: Failed to import meshtastic package"
    exit 1
}

echo "Setup complete! You can now:"
echo "1. Scan for devices: python3 meshtastic_bridge.py --scan"
echo "2. Test integration: python3 demo.py"
echo "3. Enable in BitChat settings"