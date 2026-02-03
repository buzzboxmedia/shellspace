#!/bin/bash
# ClaudeHub Install Script
# Builds, installs, and pushes to GitHub

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeHub"
APP_PATH="$HOME/Applications/$APP_NAME.app"

cd "$SCRIPT_DIR"

# Git: commit and push any changes
if [[ -n $(git status --porcelain) ]]; then
    echo "Committing changes..."
    git add -A
    git commit -m "Update $(date '+%Y-%m-%d %H:%M')"
    echo "Pushing to GitHub..."
    git push
else
    echo "No changes to commit"
fi

# Get version from git commit count (after commit so it's current)
COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")
VERSION="1.0.$COMMIT_COUNT"
echo "Version: $VERSION"

echo "Building $APP_NAME..."
swift build

# Check if app is running and quit it gracefully
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "Quitting running instance..."
    osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || killall "$APP_NAME" 2>/dev/null || true
    sleep 0.5
fi

# Check if this is a fresh install or an update
if [ -d "$APP_PATH" ]; then
    echo "Updating existing app..."
    FRESH_INSTALL=false
else
    echo "Creating app bundle..."
    mkdir -p "$APP_PATH/Contents/MacOS"
    mkdir -p "$APP_PATH/Contents/Resources"
    FRESH_INSTALL=true
fi

# Copy executable (update in place)
cp ".build/debug/$APP_NAME" "$APP_PATH/Contents/MacOS/"

# Copy icon
if [ -f "$SCRIPT_DIR/ClaudeHub/Resources/AppIcon.icns" ]; then
    mkdir -p "$APP_PATH/Contents/Resources"
    cp "$SCRIPT_DIR/ClaudeHub/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/"
fi

# Always update Info.plist (version changes each build) - MUST be before codesign
cat > "$APP_PATH/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeHub</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.buzzbox.claudehub</string>
    <key>CFBundleName</key>
    <string>ClaudeHub</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>ClaudeHub uses the microphone for voice dictation to send commands to Claude.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>ClaudeHub uses speech recognition to convert your voice into text commands for Claude.</string>
</dict>
</plist>
PLIST

# Sign the app with entitlements for CloudKit (after Info.plist exists)
echo "Signing with entitlements..."
codesign --force --sign - --entitlements "$SCRIPT_DIR/ClaudeHub.entitlements" "$APP_PATH"

# Register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH"

# Ensure app is in Dock (check every time, only modify if missing)
python3 << PYTHON
import subprocess
import plistlib

APP_PATH = "$APP_PATH"

# Get current dock apps
result = subprocess.run(['defaults', 'export', 'com.apple.dock', '-'], capture_output=True)
dock = plistlib.loads(result.stdout)

# Check if ClaudeHub is already in the Dock
already_in_dock = any(
    'ClaudeHub' in app.get('tile-data', {}).get('file-data', {}).get('_CFURLString', '')
    for app in dock.get('persistent-apps', [])
)

if not already_in_dock:
    # Add ClaudeHub
    dock['persistent-apps'].append({
        'tile-data': {
            'file-data': {
                '_CFURLString': f'file://{APP_PATH}/',
                '_CFURLStringType': 15
            }
        }
    })

    # Write back
    plist_data = plistlib.dumps(dock)
    subprocess.run(['defaults', 'import', 'com.apple.dock', '-'], input=plist_data)
    subprocess.run(['killall', 'Dock'])
    print("✓ Added to Dock")
else:
    print("✓ Already in Dock")
PYTHON

# Add to Login Items (so menu bar icon is always available)
osascript << 'APPLESCRIPT'
tell application "System Events"
    set appPath to POSIX file (POSIX path of (path to home folder) & "/Applications/ClaudeHub.app") as alias
    set loginItems to name of every login item
    if "ClaudeHub" is not in loginItems then
        make login item at end with properties {path:appPath, hidden:false}
        log "✓ Added to Login Items"
    end if
end tell
APPLESCRIPT
echo "✓ ClaudeHub will start at login"

if [ "$FRESH_INSTALL" = true ]; then
    echo "✓ Installed to $APP_PATH"
else
    echo "✓ Updated $APP_PATH"
fi

# Add 'build' alias if not already in shell config
if ! grep -q "alias build=" ~/.zshrc 2>/dev/null; then
    echo "" >> ~/.zshrc
    echo "# ClaudeHub build command" >> ~/.zshrc
    echo "alias build=\"$SCRIPT_DIR/install.sh\"" >> ~/.zshrc
    echo "✓ Added 'build' alias to ~/.zshrc"
fi

# Relaunch the app
echo "Launching $APP_NAME..."
open "$APP_PATH"
