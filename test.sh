# If Homebrew isn't installed:
# (skip if `brew --version` works)
 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
 echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
 eval "$(/opt/homebrew/bin/brew shellenv)"

# Install just
brew install just

# Verify
just --version

# From the repo root, run the macOS recipe
cd /Users/cw/Documents/GitHub/bitchat
just -l
just run