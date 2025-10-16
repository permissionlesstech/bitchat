#!/bin/bash

# BitChat Entitlements Setup Script
# Automatically configures entitlements with the correct bundle ID

set -e  # Exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOCAL_CONFIG="$PROJECT_ROOT/Configs/Local.xcconfig"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 BitChat Entitlements Setup${NC}"
echo "=================================="

# Check if Local.xcconfig exists
if [ ! -f "$LOCAL_CONFIG" ]; then
    echo -e "${RED}❌ Local.xcconfig not found${NC}"
    echo "Please copy Configs/Local.xcconfig.example to Configs/Local.xcconfig first"
    echo "and add your DEVELOPMENT_TEAM ID"
    exit 1
fi

# Extract the team ID from Local.xcconfig
TEAM_ID=$(grep "DEVELOPMENT_TEAM" "$LOCAL_CONFIG" | cut -d'=' -f2 | sed 's/[[:space:]]//g' | sed 's/\$(.*)//' | head -1)

if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "ABC123" ]; then
    echo -e "${RED}❌ DEVELOPMENT_TEAM not configured${NC}"
    echo "Please edit Configs/Local.xcconfig and set your Apple Developer Team ID"
    echo ""
    echo "Find your Team ID at:"
    echo "  Xcode → Preferences → Accounts → Apple ID → Team ID"
    echo ""
    echo "Then update Local.xcconfig:"
    echo "  DEVELOPMENT_TEAM = YOUR_TEAM_ID_HERE"
    exit 1
fi

echo -e "${GREEN}✅ Found Team ID: $TEAM_ID${NC}"

# Find all entitlements files
ENTITLEMENTS_FILES=$(find "$PROJECT_ROOT" -name "*.entitlements" -type f)

if [ -z "$ENTITLEMENTS_FILES" ]; then
    echo -e "${RED}❌ No entitlements files found${NC}"
    exit 1
fi

echo -e "${BLUE}📝 Found entitlements files:${NC}"
for file in $ENTITLEMENTS_FILES; do
    echo "  $(basename "$file")"
done

# Create backup directory if it doesn't exist
BACKUP_DIR="$PROJECT_ROOT/.entitlements-backup"
mkdir -p "$BACKUP_DIR"

# Update each entitlements file
echo -e "${BLUE}🔄 Updating entitlements...${NC}"

for file in $ENTITLEMENTS_FILES; do
    filename=$(basename "$file")
    echo -e "  Processing ${YELLOW}$filename${NC}..."
    
    # Create backup
    cp "$file" "$BACKUP_DIR/$filename.backup"
    
    # Check if file contains the generic group identifier
    if grep -q "group.chat.bitchat" "$file" && ! grep -q "group.chat.bitchat.$TEAM_ID" "$file"; then
        # Update the file
        sed -i.tmp "s/group\.chat\.bitchat/group.chat.bitchat.$TEAM_ID/g" "$file"
        rm "$file.tmp"
        echo -e "    ${GREEN}✅ Updated group identifier${NC}"
    else
        echo -e "    ${YELLOW}⚠️  Already configured or no changes needed${NC}"
    fi
done

# Verify the changes
echo -e "${BLUE}🔍 Verifying changes...${NC}"
VERIFICATION_FAILED=false

for file in $ENTITLEMENTS_FILES; do
    filename=$(basename "$file")
    if grep -q "group.chat.bitchat.$TEAM_ID" "$file"; then
        echo -e "  ${GREEN}✅ $filename${NC}: group.chat.bitchat.$TEAM_ID"
    else
        echo -e "  ${RED}❌ $filename${NC}: Update failed"
        VERIFICATION_FAILED=true
    fi
done

if [ "$VERIFICATION_FAILED" = true ]; then
    echo -e "${RED}❌ Some files failed to update${NC}"
    echo "Backups are available in .entitlements-backup/"
    exit 1
fi

echo ""
echo -e "${GREEN}🎉 Entitlements setup complete!${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Review the changes: git diff"
echo "  2. Test the build: just build"
echo "  3. If issues occur, restore from backups in .entitlements-backup/"
echo ""
echo -e "${YELLOW}Note:${NC} This script updated app group identifiers for your Team ID"
echo "This ensures your development build won't conflict with other versions"