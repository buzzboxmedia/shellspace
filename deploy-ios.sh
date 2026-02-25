#!/bin/bash
set -e
security unlock-keychain -p 9991 ~/Library/Keychains/login.keychain-db
echo "Keychain unlocked"
cd ~/Code/shellspace
git fetch origin && git reset --hard origin/main
# Rebuild and relaunch Mac server
pkill -f Shellspace 2>/dev/null || true
swift build 2>&1 | tail -3
open .build/debug/Shellspace
sleep 3
echo "Server relaunched"
# Build iOS app
cd ShellspaceIOS
xcodebuild -project ShellspaceIOS.xcodeproj -scheme ShellspaceIOS -sdk iphoneos build 2>&1 | tail -5
echo "iOS build complete!"
