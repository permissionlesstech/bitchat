#!/bin/bash
# Install Meshtastic dependencies for BitChat integration
# This script should be run once to set up the Python environment

echo "Installing Meshtastic integration dependencies..."

# Check if Python3 is available
if ! command -v python3 &> /dev/null; then
    echo "Error: Python3 is required but not installed"
    exit 1
fi

# Install pip if not available
if ! command -v pip3 &> /dev/null; then
    echo "Installing pip..."
    python3 -m ensurepip --default-pip
fi

# Install required packages
echo "Installing Python packages..."
pip3 install -r requirements_meshtastic.txt

echo "Meshtastic integration setup complete!"
echo "You can now enable Meshtastic fallback in BitChat settings."
